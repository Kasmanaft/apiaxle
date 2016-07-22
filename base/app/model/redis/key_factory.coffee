# This code is covered by the GPL version 3.
# Copyright 2011-2013 Philip Jackson.
_     = require "lodash"
async = require "async"

{ Redis, Model } = require "../redis"
{ ValidationError } = require "../../../lib/error"

class Key extends Model
  @factory = "keyfactory"

  linkToApi: ( apiName, cb ) -> @hset "#{ @id }-apis", apiName, 1, cb
  supportedApis: ( cb ) -> @hkeys "#{ @id }-apis", cb
  unlinkFromApi: ( apiName, cb ) -> @hdel "#{ @id }-apis", apiName, cb
  isLinkedToApi: ( api_name, cb ) -> @fHexists "#{ @id }-apis", api_name, cb

  linkToKeyring: ( krName, cb ) -> @hset "#{ @id }-keyrings", krName, 1, cb
  supportedKeyrings: ( cb ) -> @hkeys "#{ @id }-keyrings", cb
  unlinkFromKeyring: ( krName, cb ) -> @hdel "#{ @id }-keyrings", krName, cb
  isLinkedToKeyring: ( api_name, cb ) -> @fHexists "#{ @id }-keyrings", api_name, cb

  isDisabled: ( ) -> @data.disabled

  delete: ( cb ) ->
    @supportedApis ( err, api_list ) =>
      return cb err if err

      @supportedKeyrings ( err, keyring_list ) =>
        return cb err if err

        unlinker_fns = []

        # find each of the apis/keyrings and unlink ourselves from it
        for api in api_list
          do( api ) =>
            unlinker_fns.push ( cb ) =>
              @app.model( "apifactory" ).find [ api ], ( err, results ) =>
                return cb err if err
                return results[api].unlinkKey @, cb

        # find each of the apis and unlink ourselves from it
        for keyring in keyring_list
          do( keyring ) =>
            unlinker_fns.push ( cb ) =>
              @app.model( "keyringfactory" ).find [ keyring ], ( err, results ) =>
                return cb err if err
                return results[keyring].unlinkKey @, cb

        async.parallel unlinker_fns, ( err ) =>
          return cb err if err
          return Key.__super__.delete.apply @, [ cb ]

  update: ( new_data, cb ) ->
    # if someone has upped the qpd then we need to take account as
    # their current qpd counter might be at a value below what they
    # would now be allowed
    limits_model = @app.model "apilimits"
    redis_key_name = limits_model.qpdKey @id

    all_actions = []
    limits_model.get redis_key_name, ( err, current_qpd ) =>
      return cb err if err

      # run the original update
      all_actions.push ( cb ) =>
        @constructor.__super__.update.apply @, [ new_data, cb ]

      async.parallel all_actions, ( err, [ discard..., res ] ) ->
        return cb err if err
        return cb null, res...

class exports.KeyFactory extends Redis
  @instantiateOnStartup = true
  @smallKeyName = "key"
  @returns      = Key

  @structure =
    type: "object"
    additionalProperties: false
    properties:
      createdAt:
        type: "integer"
        optional: true
      updatedAt:
        type: "integer"
        optional: true
      sharedSecret:
        type: "string"
        optional: true
        docs: "A shared secret which is used when signing a call to the api."
      qpd:
        type: "integer"
        docs: "Number of queries that can be called per day. Set to `-1` for no limit."
      qpm:
        type: "integer"
        docs: "Number of queries that can be called per minute. Set to `-1` for no limit."
      qps:
        type: "integer"
        docs: "Number of queries that can be called per second. Set to `-1` for no limit."
      group:
        optional: true
        type: "string"
        docs: "Allow this key to work with all APIs with a matching group."
      forApis:
        optional: true
        type: "array"
        docs: "Names of the Apis that this key belongs to."
      disabled:
        type: "boolean"
        default: false
        docs: "Disable this API causing errors when it's hit."
      groupLimits:
        type: "string"
        docs: 'Custom limits for apis in group. JSON encoded: \'{"api1": {"qpd":5, "qps":2}, "api2": {"qpd":2}}\''
        optional: true

  _verifyApisExist: ( apis, cb ) ->
    if not apis
      return cb null
    allApiExistsChecks = []

    for api in apis
      do( api ) =>
        allApiExistsChecks.push ( cb ) =>
          @app.model( "apifactory" ).find [ api ], ( err, results ) ->
            return cb err if err

            if not results[api]
              return cb new ValidationError "API '#{ api }' doesn't exist."
            return cb null, results[api]

    async.parallel allApiExistsChecks, cb

  _verifyGroupLimits: ( groupLimits, group, cb ) ->
    if not groupLimits || not group
      return cb null
    try
      parsedLimits = JSON.parse groupLimits
    catch
      return cb new ValidationError "groupLimits is invalid JSON"
    allApiExistsChecks = []

    for api, limits of parsedLimits
      for limit of limits

        if limit not in ['qpd','qpm','qps']
          return cb new ValidationError "Unsupported limit type '#{ limit }'"

        if typeof limits[limit] != 'number' || Math.round(limits[limit]) != limits[limit]
          return cb new ValidationError "groupLimits['#{ api }']['#{ limit }'] must be an integer"

      do( api ) =>
        allApiExistsChecks.push ( cb ) =>
          @app.model( "apifactory" ).find [ api ], ( err, results ) ->
            return cb err if err

            if not results[api]
              return cb new ValidationError "API '#{ api }' doesn't exist."
            if not(results[api].data.group == group)
              return cb new ValidationError "API '#{ api }' isn't part of group '#{ group }'."
            return cb null

    async.parallel allApiExistsChecks, cb

  _linkKeyToApis: ( dbApis, dbKey, cb ) ->
    allKeysLink = []

    for api in dbApis
      do( api ) ->
        allKeysLink.push ( cb ) ->
          api.linkKey dbKey.id, ( err ) ->
            return cb err if err
            return cb null, dbKey

    async.parallel allKeysLink, cb

  create: ( id, details, cb ) ->
    # if there isn't a forApis or groupLimits field then let `super` create
    if not (details?.forApis? || details?.groupLimits?)
      return super

    @_verifyGroupLimits details.groupLimits, details.group, ( err ) =>
      return cb err if err

      if details.forApis
        # grab the apis this should belong to and then delete the key pair
        # because we don't actually want to store it.
        forApis = details.forApis
        delete details.forApis

      # first we need to make sure all of the apis actually
      # exist. #create should behave atomically if possible
      @_verifyApisExist forApis, ( err, dbApis ) =>
        return cb err if err

        # this creates the actual key
        @callConstructor id, details, ( err, dbKey ) =>
          return cb err if err
          if not dbApis
            return cb null, dbKey
          @_linkKeyToApis dbApis, dbKey, ( err ) =>
            return cb err if err
            return cb null, dbKey
