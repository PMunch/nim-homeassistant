import asyncdispatch, json, strutils, lists, os
import ws
#import "./times.nim"

type
  Device = object
    brightness: int
    auto: bool
  Time = object
    hour, minute: int
  HomeAssistant* = ref object
    messageId: int
    messages*: DoublyLinkedList[JsonNode]
    socket*: WebSocket

template yieldAsync() =
  await sleepAsync(0)

proc initHome*(address, token: string): Future[HomeAssistant] {.async.} =
  new result
  result.socket = await newWebSocket("ws://" & address & "/api/websocket")
  var response = parseJson(await result.socket.receiveStrPacket())
  #echo response
  assert response["type"].str == "auth_required"
  await result.socket.send($(%*{"type": "auth", "access_token": token}))
  response = parseJson(await result.socket.receiveStrPacket())
    #echo response
  assert response["type"].str == "auth_ok"
  result.messages = initDoublyLinkedList[JsonNode]()
  result.messageId = 1

template initHome*(): untyped =
  initHome("ws://supervisor/core/websocket", getEnv("SUPERVISOR_TOKEN"))

proc runLoop*(home: HomeAssistant) {.async.} =
  while true:
    var response = ""
    while response.len == 0:
      response = await home.socket.receiveStrPacket()
    var message: JsonNode
    try: message = parseJson(response) except: continue
    home.messages.append(message)

proc close*(home: HomeAssistant) {.async.} =
  home.socket.close()

proc receiveMessageInternal(home: HomeAssistant, recurringId: int): Future[DoublyLinkedNode[JsonNode]] {.async.} =
  var node: DoublyLinkedNode[JsonNode]
  while node == nil:
    yieldAsync
    node = home.messages.head

  while node.value["id"].num != recurringId:
    while node.next == nil:
      yieldAsync
    node = node.next

  return node

proc receiveMessage*(home: HomeAssistant, recurringId: int): Future[JsonNode] {.async.} =
  var node = await home.receiveMessageInternal(recurringId)
  home.messages.remove node
  return node.value

proc sendMessage*(home: HomeAssistant, message: JsonNode): Future[JsonNode] {.async.} =
  var message = message
  let messageId = home.messageId
  message["id"] = %messageId
  inc home.messageId
  await home.socket.send($message)

  return await home.receiveMessage(messageId)

proc sendRecurringMessage*(home: HomeAssistant, message: JsonNode): Future[int] {.async.} =
  var message = message
  result = home.messageId
  message["id"] = %result
  inc home.messageId
  await home.socket.send($message)
  assert (await home.receiveMessage(result))["success"].bval == true
#func timeDifference(start, stop: Time): int =
#  const
#    MINS_PER_HR = 60
#    MINS_PER_DAY = 1440
#
#  let
#    startx = start.hour * MINS_PER_HR + start.minute
#    stopx = stop.hour * MINS_PER_HR + stop.minute
#
#  result = stopx - startx
#  if result < 0:
#      result += MINS_PER_DAY
#
#proc toTimestamp(startTime: DateTime): float =
#  var time = now()
#  if time.hour > startTime.hour or (time.hour == startTime.hour and time.minute >= startTime.minute):
#    time += 1.days
#  time.hour = startTime.hour
#  time.minute = startTime.minute
#  time.second = 0
#
#  return time.toTime.toUnix.float
#
#proc parseTime(x: string): DateTime =
#  parse("2020 " & x, "yyyy HH:mm")
#
#proc setLights(lights: seq[string], newValue: int) {.async.} =
#  var
#    socket = await initHome()
#    response = await socket.sendMessage(%*{"type": "get_states"})
#    booleans: Table[string, bool]
#    devices: Table[string, Device]
#  for device in response["result"]:
#    #echo device
#    let deviceId = device["entity_id"].str
#    if deviceId["light.".len..^1] in lights:
#      let id = deviceId["light.".len..^1]
#      #echo device
#      if device["state"].str == "on":
#        devices.mgetOrPut(id, Device()).brightness = device["attributes"]["brightness"].num.int
#      else:
#        #echo id, ": off"
#        devices.mgetOrPut(id, Device()).brightness = 0
#      if booleans.hasKey(id):
#        devices[id].auto = booleans[id]
#    if deviceId.startsWith("input_boolean."):
#      let id = deviceId["input_boolean.".len..^("_auto".len + 1)]
#      booleans[id] = device["state"].str == "on"
#      devices.mgetOrPut(id, Device()).auto = booleans[id]
#  #var
#  #  ratio = (i - (start.hour*60+start.minute)*60)/((stop.hour*60+stop.minute)*60 - (start.hour*60+start.minute)*60)
#  #  newValue = minBrightness + ((maxBrightness - minBrightness).float*sin((90 + 90*ratio)/180*Pi)).int
#  #echo newValue
#  for id, device in devices:
#    echo id, ": ", device
#    if id in lights:
#      if device.auto and device.brightness > newValue:
#        echo "Setting device ", id, " to ", newValue
#        echo await socket.sendMessage(%*{"type": "call_service", "domain": "light", "service": "turn_on", "service_data": {"entity_id": "light." & id, "brightness": newValue}})
#  socket.close()
#
#import posix
#
#proc test() {.async.} =
#  let
#    options = parseFile("/data/options.json")
#    #options = %*{"maxBrightness": 255, "minBrightness": 150, "startTime": (now() + 1.minutes).format("HH:mm"), "endTime": (now() + 11.minutes).format("HH:mm"), "lights": ["living_room_lights", "kitchen_lights", "bedroom_lights", "bathroom_lights", "hallway_lights"]}
#    startTime = options["startTime"].str.parseTime
#    stopTime = options["endTime"].str.parseTime
#    duration = inSeconds(stopTime - startTime).float
#    minBrightness = options["minBrightness"].num
#    maxBrightness = options["maxBrightness"].num
#    lights = options["lights"].mapIt(it.str)
#
#  dump duration
#
#  var t = 0
#  while true:
#    let
#      startLoop = epochTime()
#      start = startTime.toTimestamp
#      stop = stopTime.toTimestamp
#      toStart = start - startLoop
#      toStop = stop - startLoop
#      sinceStart = startLoop - start
#
#    if toStart > 0 and toStart < toStop:
#      dump toStart
#      await sleepAsync(toStart * 1000)
#      continue
#
#    let
#      ratio = 1.0 - (stop - epochTime()) / duration
#      newValue = (minBrightness + ((maxBrightness - minBrightness).float*cos(ratio*Pi/2)).int).int
#
#    echo epochTime(), ", ", newValue
#    await lights.setLights(newValue)
#
#    let
#      newRatio = (newValue - minBrightness).float / (maxBrightness - minBrightness).float
#      timeRatio = arccos(newRatio) / (Pi / 2)
#      nextOffset = duration.float * (1 - timeRatio)
#      sleepingTime = (stop - nextOffset - epochTime()) * 1000
#    echo "Sleeping until next set: ", sleepingTime
#    await sleepAsync(sleepingTime)
#
#waitFor(test())

