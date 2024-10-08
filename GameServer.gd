extends Control

# TODO handle auth server being down
# TODO check in rpc calls if client is still connected

var network:ENetMultiplayerPeer = ENetMultiplayerPeer.new()
var server_running:bool = false

# token:String: username:String
var expected_tokens:Dictionary = {}
@onready var player_verification_process = get_node("PlayerVerification")

# playerid:int = [username:String, level:String, {"creaturename": creaturenode:Node3D}, kills:int]
var player_data:Dictionary = {}
# playerid:int = [creaturename:String]
var creature_cooldown:Dictionary = {}

var player_scene:PackedScene = preload("res://player/player_character.tscn")
var player_controller_scene:PackedScene = preload("res://player/PlayerInput.tscn")

var creatures:Dictionary = {
"Rat": preload("res://creatures/rat.tscn"),
"Dog": preload("res://creatures/dog.tscn"),
"Bird": preload("res://creatures/bird.tscn"),
"Cat": preload("res://creatures/cat.tscn")}

func _ready():
	_on_start_pressed()

func _on_start_pressed():
	if !server_running:
		server_running = true
		
		network.create_server(
			$Menu/PortInput.text.to_int(),
			$Menu/MaxPlayersInput.text.to_int()
		)
		
		multiplayer.multiplayer_peer = network
		
		network.peer_connected.connect(_Peer_Connected)
		network.peer_disconnected.connect(_Peer_Disconnected)
		
		$Started.show()

func _on_stop_pressed():
	if server_running:
		server_running = false
		network.peer_connected.disconnect(_Peer_Connected)
		network.peer_disconnected.disconnect(_Peer_Disconnected)
		for peer_id in multiplayer.get_peers():
			# TODO send disconnection to peers
			RemovePlayer(peer_id)
		network.close()
		
		$Started.hide()


func _Peer_Connected(peer_id:int) -> void:
	player_verification_process.Start(peer_id)


func _Peer_Disconnected(peer_id:int) -> void:
	if player_data.has(str(peer_id)):
		# TODO check if player needs to be removed anyway
		RemovePlayer(peer_id)


# game functions

func AddPlayer(username:String, player_id:int, level="Hub Level") -> void:
	if player_data.has(str(player_id)):
		print("Player already exists")
		return
		
	else:
		player_data[str(player_id)] = [username, "Hub Level", {}, 0]
	
	# set player location
	player_data[str(player_id)][1] = level
	
	# create character node
	var character = player_scene.instantiate()
	character.name = str(player_id) + " Visual"
	character.set_multiplayer_authority(1)
	get_node("Characters").add_child(character)
	
	# add character to scoreboard
	SetUpScoreBoard()
	
	initialize_controller(player_id)


func RemovePlayer(player_id:int) -> void:
	# players data
	var data:Array = player_data[str(player_id)]
	
	# TODO check if player exists (not just peer)
	
	# remove controller
	get_node(str(player_id) + " Controller").queue_free.call_deferred()
	
	# remove visual
	get_node("Characters").get_node(str(player_id) + " Visual").queue_free.call_deferred()
	
	# remove active creatures
	var player_active_creatures = data[2]
	for c_name in player_active_creatures:
		player_active_creatures[c_name].queue_free.call_deferred()
	
	player_data.erase(str(player_id))
	
	# remove from scoreboard
	SetUpScoreBoard()


func RemoveCreature(player_id:String, creature_name:String):
	var creature = player_data[player_id][2][creature_name]
	player_data[player_id][2].erase(creature_name)
	creature.queue_free.call_deferred()
	if creature_cooldown.has(player_id):
		creature_cooldown[player_id].append(creature_name)
	else:
		creature_cooldown[player_id] = [creature_name]
	await get_tree().create_timer(5).timeout
	creature_cooldown[player_id].erase(creature_name)


func ServerAddCreature(creature:String, player_id:int) -> void:
	var data:Array = player_data[str(player_id)]
	var player_controller:Node = get_node(str(player_id) + " Controller")
	var player_visual:Node3D = get_node("Characters/" + str(player_id) + " " + "Visual")
	
	if creatures.has(creature):
		# player has creature active already, or has 4 active creatures
		if data[2].has(creature) or data[2].size() >= 4: return
		
		# creature is on cooldown
		if creature_cooldown.has(str(player_id)):
			if creature_cooldown[str(player_id)].has(creature): return
		
		var creature_node:Node3D = creatures[creature].instantiate()
		# add creature to player data
		data[2][creature] = creature_node
		creature_node.name = str(player_id) + " " + creature_node.name
		creature_node.set_multiplayer_authority(1)
		get_node("Characters").add_child(creature_node)
		creature_node.global_position = player_visual.global_position
		
		player_controller.server_added_creature(creature_node.name)
	else:
		print("Player " + str(player_id) + " tried to add creature " + creature + " that server doesnt have")


func RespawnPlayer(player_id:String):
	if player_data.has(player_id):
		var data:Array = player_data[player_id]
		var player:Node3D = get_node("Characters").get_node(player_id + " Visual")
		
		# remove active creatures
		var player_active_creatures = data[2]
		for c_name in player_active_creatures:
			player_active_creatures[c_name].queue_free.call_deferred()
		data[2] = {}
		
		# reset player health and move them
		player.reset_health()
		player.global_position = Vector3(0,0.5,0)


func IncreasePlayerKills(player_id:String, kills:int):
	var data:Array = player_data[player_id]
	data[3] += kills
	
	# update scoreboard
	var scoreboard_text:String = get_node("Scoreboard").text
	var scoreboard_array = scoreboard_text.split("\n")
	var text_out:String = ""
	
	for entry in scoreboard_array:
		if data[0] == entry.split(":")[0]:
			entry = data[0] + ": " + str(data[3])
		text_out += entry + "\n"
	
	get_node("Scoreboard").text = text_out


func SetUpScoreBoard():
	var scoreboard:Label = get_node("Scoreboard")
	scoreboard.text = ""
	for id in player_data:
		scoreboard.text += player_data[id][0] + ": " + str(player_data[id][3]) + "\n"


# Player account verification functions

func PlayerLoggedIn(username:String):
	for token in player_data.keys():
		if player_data[token][0] == username:
			return true
	return false


# Player token functions

@rpc("authority", "call_remote")
func FetchToken(player_id:int) -> void:
	print("Fetching player token")
	rpc_id(player_id, "FetchToken")

@rpc("any_peer", "call_remote")
func ReturnToken(token:String) -> void:
	print("Player returned token")
	var player_id = multiplayer.get_remote_sender_id()
	player_verification_process.Verify(player_id, token)

@rpc("authority", "call_remote")
func ReturnTokenVerificationResults(player_id:int, result:bool) -> void:
	print("Sending player token verification results")
	rpc_id(player_id, "ReturnTokenVerificationResults", result)


# Every 30 seconds remove tokens that have expired
func _on_token_expiration_timeout():
	if !expected_tokens.is_empty():
		var current_time:float = Time.get_unix_time_from_system()
		var token_time:float
		for i in range(expected_tokens.size()-1, -1, -1):
			var token:String = expected_tokens.keys()[i]
			token_time = float(token.split(" ")[1])
			if current_time - token_time >= 30:
				expected_tokens.erase(token)


@rpc("authority", "call_remote")
func initialize_controller(player_id:int):
	var player_controller = player_controller_scene.instantiate()
	player_controller.name = str(player_id) + " Controller"
	player_controller.set_multiplayer_authority(player_id)
	add_child(player_controller)
	rpc_id(player_id, "initialize_controller")
