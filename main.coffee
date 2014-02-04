ROOT_RESOURCE_ID = 0

browserPipe = null
rendererPipe = null

# Common.
class Pipe
  constructor: (@name, @receiver) ->

  send: (msg) ->
    console.log @name, msg
    @receiver.receive msg

# Browser.
class ResourceHost
  constructor: (@resourceManager) ->
    @id = @resourceManager.register @

  send: (msg) ->
    msg.target = @id
    rendererPipe.send msg

  receive: (msg) ->
    switch msg.name
      when 'close' then @resourceManager.close @
      else
        return false
    true

class IntStoreResourceHost extends ResourceHost
  constructor: (@resourceManager) ->
    super
    @value = 0

  handleSet: (msg) ->
    @value = msg.value

  handleGet: (msg) ->
    @send {
      name: 'got'
      @value
    }

  receive: (msg) ->
    return if super
    switch msg.name
      when 'set' then @handleSet msg
      when 'get' then @handleGet msg

class RootResourceHost extends ResourceHost
  constructor: (@resourceManager) ->
    super
    @factories = {}

  addHostFactory: (name, factory) ->
    @factories[name] = factory

  create: (msg) ->
    resource = @factories[msg.type] @resourceManager
    @send {
      name: 'OnCreate'
      callbackId: msg.callbackId
      createdId: resource.id
    }

  receive: (msg) ->
    return if super
    switch msg.name
      when 'create' then @create msg

class ResourceManager
  constructor: ->
    @lastId = 0
    @resources = {}

  register: (resource) ->
    id = @lastId++
    @resources[id] = resource
    id

  receive: (msg) ->
    @resources[msg.target].receive msg

  close: (resource) ->
    delete @resources[resource.id]

# Renderer.
class ResourceManagerClient
  constructor: ->
    @resources = {}

  register: (id, resource) ->
    # console.log 'registering', id, 'in ResourceManagerClient'
    @resources[id] = resource

  receive: (msg) ->
    # console.log 'ResourceManagerClient.receive', msg
    # console.log {@resources}
    @resources[msg.target].receive msg

  flush: ->
    for id, r of @resources
      r.flush()

  close: ->
    for id, r of @resources
      r.close()

class Resource
  constructor: (@id, @rmc) ->
    @rmc.register @id, @

  send: (msg) ->
    msg.target = @id
    browserPipe.send msg

  receive: (msg) ->
  flush: ->
  close: ->
    @send {name: 'close'}

class IntStoreResource extends Resource
  constructor: (id, rmc) ->
    super
    @pendingCallback = null

  set: (value) ->
    @send {
      name: 'set'
      value
    }

  get: (callback) ->
    @pendingCallback = callback
    @send {
      name: 'get'
    }

  got: (msg) ->
    p = @pendingCallback
    @pendingCallback = null
    p msg.value

  receive: (msg) ->
    switch msg.name
      when 'got' then @got msg

class RootResource extends Resource
  constructor: (@rmc) ->
    super ROOT_RESOURCE_ID, @rmc
    @pendingCreates = {}
    @currentCallbackId = 0
    @factories = {}

  registerFactory: (id, factory) ->
    @factories[id] = factory

  create: (type, callback) ->
    callbackId = @currentCallbackId++
    @pendingCreates[callbackId] = {
      callback
      type
    }
    @send {
      callbackId
      name: 'create'
      type
    }

  onCreate: (msg) ->
    p = @pendingCreates[msg.callbackId]
    delete @pendingCreates[msg.callbackId]

    resource = @factories[p.type](msg.createdId, @rmc)
    p.callback resource

  receive: (msg) ->
    switch msg.name
      when 'OnCreate' then @onCreate msg

# Non-system code.
class BrowserProcess
  constructor: ->
    @rm = new ResourceManager
    browserPipe = new Pipe '>>', @rm
    @rrh = new RootResourceHost @rm
    @rrh.addHostFactory 'IntStore', (rm) ->
      new IntStoreResourceHost rm

class RendererProcess
  constructor: ->
    @rmc = new ResourceManagerClient
    @rr = new RootResource @rmc
    @rr.registerFactory 'IntStore', (id, rmc) ->
      new IntStoreResource id, rmc
    rendererPipe = new Pipe '<<', @rmc

  createAndUseIntStore: ->
    @rr.create 'IntStore', (intStore) ->
      intStore.set 10
      intStore.get (x) ->
        console.log x

  shutdown: ->
    @rmc.flush()
    @rmc.close()

bp = new BrowserProcess
rp = new RendererProcess

rp.createAndUseIntStore()
rp.shutdown()

console.log bp.rm
