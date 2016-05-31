_     = require 'lodash'
async = require 'async'
debug = require('debug')('meshblu-core-job-manager:job-manager')
uuid  = require 'uuid'

class JobManager
  constructor: (options={}) ->
    {@client,@jobLogPrefix,@jobLogSampleRate,@jobLogSampleRateOverrideUuids,@timeoutSeconds} = options
    @jobLogPrefix ?= ''
    throw new Error 'JobManager constructor is missing "client"' unless @client?
    throw new Error 'JobManager constructor is missing "jobLogSampleRate"' unless @jobLogSampleRate?
    throw new Error 'JobManager constructor is missing "timeoutSeconds"' unless @timeoutSeconds?

  addMetric: (metadata, metricName, callback) =>
    return callback() unless metadata.logJob
    metadata.metrics ?= {}
    metadata.metrics[metricName] = Date.now()
    callback()

  createForeverRequest: (requestQueue, options, callback) =>
    {metadata,data,rawData,ignoreResponse} = options
    metadata = _.clone metadata
    metadata.responseId ?= uuid.v4()

    if @jobLogSampleRateOverrideUuids?
      enabled = _.includes @jobLogSampleRateOverrideUuids, metadata.auth?.uuid
      metadata.jobLog = {enabled, override: true}
    else
      enabled = Math.random() < @jobLogSampleRate
      metadata.jobLog ?= {enabled}

    if metadata.jobLog?.enabled
      metadata.metrics = {}
      metadata.jobLog.prefix = @jobLogPrefix unless _.isEmpty @jobLogPrefix

    @addMetric metadata, 'enqueueRequestAt', (error) =>
      return callback error if error?
      {responseId} = metadata
      data ?= null

      metadataStr = JSON.stringify metadata
      rawData ?= JSON.stringify data

      values = [
        'request:metadata', metadataStr
        'request:data', rawData
        'request:createdAt', Date.now()
      ]

      if ignoreResponse
        values.push 'request:ignoreResponse'
        values.push 1

      async.series [
        async.apply @client.hmset, responseId, values
        async.apply @client.lpush, "#{requestQueue}:queue", responseId
      ], (error) =>
        delete error.code if error?
        callback error, responseId

  createRequest: (requestQueue, options, callback) =>
    @createForeverRequest requestQueue, options, (error, responseId) =>
      return callback error if error?
      @client.expire responseId, @timeoutSeconds, (error) =>
        delete error.code if error?
        callback error, responseId

  createResponse: (responseQueue, options, callback) =>
    {metadata,data,rawData} = options
    {responseId} = metadata
    @addMetric metadata, 'enqueueResponseAt', (error) =>
      return callback error if error?
      data ?= null

      metadataStr = JSON.stringify metadata
      rawData ?= JSON.stringify data

      values = [
        'response:metadata', metadataStr
        'response:data', rawData
      ]

      @client.hexists responseId, 'request:ignoreResponse', (error, ignoreResponse) =>
        delete error.code if error?
        return callback error if error?

        if ignoreResponse == 1
          @client.del responseId, (error) =>
            delete error.code if error?
            callback error
          return

        async.series [
          async.apply @client.hmset, responseId, values
          async.apply @client.expire, responseId, @timeoutSeconds
          async.apply @client.lpush, "#{responseQueue}:#{responseId}", responseId
          async.apply @client.expire, "#{responseQueue}:#{responseId}", @timeoutSeconds
        ], (error) =>
          delete error.code if error?
          callback error

  do: (requestQueue, responseQueue, options, callback) =>
    options = _.clone options

    @createRequest requestQueue, options, (error, responseId) =>
      return callback error if error?
      @getResponse responseQueue, responseId, callback

  getRequest: (requestQueues, callback) =>
    return callback new Error 'First argument must be an array' unless _.isArray requestQueues
    queues = _.map requestQueues, (queue) => "#{queue}:queue"
    @client.brpop queues..., @timeoutSeconds, (error, result) =>
      return callback error if error?
      return callback() unless result?

      [channel,key] = result

      @client.hgetall key, (error, result) =>
        delete error.code if error?
        return callback error if error?
        return callback() unless result?
        return callback() unless result['request:metadata']?

        metadata = JSON.parse result['request:metadata']
        @addMetric metadata, 'dequeueRequestAt', (error) =>
          return callback error if error?

          request =
            createdAt: result['request:createdAt']
            metadata:  metadata
            rawData:   result['request:data']

          callback null, request

  getResponse: (responseQueue, responseId, callback) =>
    @client.brpop "#{responseQueue}:#{responseId}", @timeoutSeconds, (error, result) =>
      delete error.code if error?
      return callback error if error?
      return callback new Error('Response timeout exceeded'), null unless result?

      [channel,key] = result

      @client.hmget key, ['response:metadata', 'response:data'], (error, data) =>
        delete error.code if error?
        return callback error if error?

        @client.del key, "#{responseQueue}:#{responseId}", (error) =>
          delete error.code if error?
          return callback error if error?

          [metadata, rawData] = data
          return callback new Error('Response timeout exceeded'), null unless metadata?

          metadata = JSON.parse metadata
          @addMetric metadata, 'dequeueResponseAt', (error) =>
            return callback error if error?

            response =
              metadata: metadata
              rawData: rawData

            callback null, response

module.exports = JobManager
