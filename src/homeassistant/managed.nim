import asyncdispatch, json, tables, lists, strutils
import ws
import base

type
  EventCallback* = proc (node: JsonNode) {.async.}
  EventHandler* = object
    eventType: string
    matches: JsonNode
    callback: EventCallback
  HomeAssistant* = ref object
    base: base.HomeAssistant
    eventIds: Table[string, BiggestInt]
    eventHandlers: Table[BiggestInt, seq[EventHandler]]

template yieldAsync() =
  await sleepAsync(0)

proc initHome*(address, token: string): Future[HomeAssistant] {.async.} =
  new result
  result.base = await base.initHome(address, token)

proc onEvent*(home: HomeAssistant, eventType: string, matches: JsonNode, callback: EventCallback) {.async.} =
  if not home.eventIds.hasKey(eventType):
    home.eventIds[eventType] = await home.base.sendRecurringMessage(%*{"type": "subscribe_events", "event_type": eventType})
  home.eventHandlers.mgetOrPut(home.eventIds[eventType], @[]).add EventHandler(eventType: eventType, matches: matches, callback: callback)

template onEvent*(home: HomeAssistant, eventType: string, callback: EventCallback): Future[void] =
  home.onEvent(eventType,nil, callback)

proc callService*(home: HomeAssistant, service: string, data: JsonNode): Future[bool] {.async.} =
  let
    domainService = service.split(".", maxSplit = 1)
    response = await home.base.sendMessage(%*{"type": "call_service", "domain": domainService[0], "service": domainService[1], "service_data": data})
  return response["success"].bval

proc compareNode(left, right: JsonNode): bool =
  result = true
  if left.kind != JObject:
    if left != right:
      return false
  else:
    for key, value in left:
      if not right.hasKey(key):
        return false
      if not compareNode(value, right[key]):
        return false

proc checkEvent(home: HomeAssistant, message: JsonNode) {.async.} =
  var handlers = home.eventHandlers[message["id"].num]
  for handler in handlers:
    if handler.matches == nil:
      asyncCheck handler.callback(message["event"]["data"])
    elif compareNode(handler.matches, message["event"]["data"]):
      asyncCheck handler.callback(message["event"]["data"])

proc runLoop*(home: HomeAssistant) {.async.} =
  while home.base.socket.readyState != Closed:
    var response = ""
    while response.len == 0:
      try:
        response = await home.base.socket.receiveStrPacket()
      except WebSocketError:
        if home.base.socket.readyState == Closed: return
    var message: JsonNode
    try: message = parseJson(response) except: continue
    if message["id"].num in home.eventHandlers:
      await home.checkEvent(message)
    else:
      home.base.messages.append(message)

template close*(home: HomeAssistant): Future[void] =
  base.close(home.base)

template receiveMessage*(home: HomeAssistant, recurringId: int): Future[JsonNode] =
  base.receiveMessage(home.base, recurringId)

template sendMessage*(home: HomeAssistant, message: JsonNode): Future[JsonNode] =
  base.sendMessage(home.base, message)

template sendRecurringMessage*(home: HomeAssistant, message: JsonNode): Future[int] =
  base.sendRecurringMessage(home.base, message)

proc getStates*(home: HomeAssistant): Future[Table[string, JsonNode]] {.async.} =
  let data = (await home.sendMessage(%*{"type": "get_states"}))["result"]
  for entity in data:
    result[entity["entity_id"].str] = entity
