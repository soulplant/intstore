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
  constructor: (@name, @resourceManager) ->
    @id = @resourceManager.register @

  send: (msg) ->
    msg.target = @id
    rendererPipe.send msg

  receive: (msg) ->
    switch msg.name
      when 'close' then @close()
      else
        return false
    true

  close: ->
    @resourceManager.close @

class IntStoreResourceHost extends ResourceHost
  constructor: (@resourceManager) ->
    super 'IntStore', @resourceManager
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

  close: ->
    # TODO Add an api for this.

class RootResourceHost extends ResourceHost
  constructor: (@resourceManager) ->
    super 'Root', @resourceManager
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

  restoreResources: ->
    @send {
      name: 'RestoreResources'
      resources: @resourceManager.getResourceHandles()
    }

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

  getResourceHandles: ->
    {id, name: r.name} for id, r of @resources

# Renderer.
class ResourceManagerClient
  constructor: ->
    @resources = {}
    @onRestore = ->

  fireOnRestore: ->
    @onRestore @resources

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

  onRestoreResources: (msg) ->
    for id, resource of msg.resources
      @factories[resource.name](resource.id, @rmc)
    @rmc.fireOnRestore()

  receive: (msg) ->
    switch msg.name
      when 'OnCreate' then @onCreate msg
      when 'RestoreResources' then @onRestoreResources msg
      else console.log 'cant handle', msg.name

# Non-system code.
class BrowserProcess
  constructor: ->
    @rm = new ResourceManager
    browserPipe = new Pipe '>>', @rm
    @rrh = new RootResourceHost @rm
    @rrh.addHostFactory 'IntStore', (rm) ->
      new IntStoreResourceHost rm

  restore: ->
    @rrh.restoreResources()

rememberedId = null

class RendererProcess
  constructor: ->
    @rmc = new ResourceManagerClient
    @rmc.onRestore = (resources) ->
      resources[rememberedId].get (x) ->
        console.log 'the value, after restore, is...', x
    @rr = new RootResource @rmc
    @rr.registerFactory 'IntStore', (id, rmc) ->
      new IntStoreResource id, rmc
    rendererPipe = new Pipe '<<', @rmc

  createAndUseIntStore: ->
    @rr.create 'IntStore', (intStore) ->
      rememberedId = intStore.id
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

rp = new RendererProcess
bp.restore()

# console.log 'rm', bp.rm
# console.log 'rmc', rp.rmc
