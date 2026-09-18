#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "2.0"
#define MAX_EDICTS (1 << 11)
#define INVALID_ROCKET_INDEX -1
#define DESYNC_SOUND "misc/banana_slip.wav"

public Plugin myinfo =
{
	name = "Desync Detector",
	author = "Laurens",
	description = "Detects rocket damage desyncs caused by usercmd/server tick divergence",
	version = PLUGIN_VERSION,
};

ConVar g_cvEnabled;
ConVar g_cvChat;
ConVar g_cvConsole;
ConVar g_cvBlockDamage;
ConVar g_cvSound;

int g_iCmdSerial[MAXPLAYERS + 1];
int g_iCmdTickBaseBefore[MAXPLAYERS + 1];
bool g_bInsideRunCmd[MAXPLAYERS + 1];
bool g_bDetectorEnabled[MAXPLAYERS + 1];
bool g_bShowAllDeltas[MAXPLAYERS + 1];
bool g_bDebugDetails[MAXPLAYERS + 1];

int g_iRocketOwner[MAX_EDICTS];
int g_iRocketRef[MAX_EDICTS];
int g_iRocketCreatedCmd[MAX_EDICTS];
int g_iRocketSimCount[MAX_EDICTS];
float g_flRocketLastOrigin[MAX_EDICTS][3];
bool g_bRocketCreatedInsideCmd[MAX_EDICTS];
bool g_bRocketDamageChecked[MAX_EDICTS];
bool g_bRocketDamageBlocked[MAX_EDICTS];
bool g_bRocketHasLastOrigin[MAX_EDICTS];
int g_iFirstTrackedRocket;
int g_iFirstClientRocket[MAXPLAYERS + 1];
int g_iNextTrackedRocket[MAX_EDICTS];
int g_iPrevTrackedRocket[MAX_EDICTS];
int g_iNextClientRocket[MAX_EDICTS];
int g_iPrevClientRocket[MAX_EDICTS];

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("sm_desyncdetector_enabled", "1", "Enable desync detector.", _, true, 0.0, true, 1.0);
	g_cvChat = CreateConVar("sm_desyncdetector_chat", "1", "Print warnings to chat.", _, true, 0.0, true, 1.0);
	g_cvConsole = CreateConVar("sm_desyncdetector_console", "1", "Print warnings to the player's console.", _, true, 0.0, true, 1.0);
	g_cvBlockDamage = CreateConVar("sm_desyncdetector_block_damage", "0", "Block rocket damage when a desync is detected.", _, true, 0.0, true, 1.0);
	g_cvSound = CreateConVar("sm_desyncdetector_sound", "0", "Play a warning sound when a desync is detected.", _, true, 0.0, true, 1.0);
	g_cvEnabled.AddChangeHook(ConVarChanged_Enabled);

	RegConsoleCmd("sm_dd", Command_ToggleDetector, "Toggle desync detector for yourself.");
	RegConsoleCmd("sm_ddall", Command_ToggleDelta, "Toggle printing all desync detector deltas.");
	RegConsoleCmd("sm_dddebug", Command_ToggleDebugDetails, "Toggle detailed desync detector output.");

	ResetAllState();
	PrecacheDesyncSound();

	for (int client = 1; client <= MaxClients; client++) {
		if (IsClientInGame(client))
			SDKHook(client, SDKHook_OnTakeDamage, OnClientTakeDamage);
	}
}

public void OnMapStart()
{
	ResetAllState();
	PrecacheDesyncSound();
}

public void OnGameFrame()
{
	if (!IsDetectorActive())
		return;

	SampleAllRocketMovement();
}

public void OnClientDisconnect(int client)
{
	ClearClientRockets(client);
	g_iCmdSerial[client] = 0;
	g_iCmdTickBaseBefore[client] = 0;
	g_bInsideRunCmd[client] = false;
	g_bDetectorEnabled[client] = true;
	g_bShowAllDeltas[client] = false;
	g_bDebugDetails[client] = false;
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnClientTakeDamage);
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (IsClientDetectorActive(client) && IsHumanPlayer(client)) {
		g_iCmdTickBaseBefore[client] = GetEntProp(client, Prop_Send, "m_nTickBase");
		g_iCmdSerial[client]++;
		g_bInsideRunCmd[client] = true;
	}

	return Plugin_Continue;
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
	bool hadCommand = g_bInsideRunCmd[client];
	g_bInsideRunCmd[client] = false;

	if (!hadCommand || !IsClientDetectorActive(client) || !IsHumanPlayer(client))
		return;

	int tickBaseDelta = GetEntProp(client, Prop_Send, "m_nTickBase") - g_iCmdTickBaseBefore[client];
	if (tickBaseDelta != 1) {
		// Rejected commands must not increase the player's simulation age.
		g_iCmdSerial[client]--;
	}

	SampleClientRocketMovement(client);
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (!IsDetectorActive())
		return;

	if (!IsRocketClass(classname))
		return;

	SDKHook(entity, SDKHook_SpawnPost, OnRocketSpawned);
}

public void OnEntityDestroyed(int entity)
{
	if (!(0 <= entity < MAX_EDICTS))
		return;

	ClearRocketSlot(entity);
}

public Action OnClientTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if (!IsDetectorActive())
		return Plugin_Continue;

	if (!(damagetype & DMG_BLAST))
		return Plugin_Continue;

	if (!IsHumanPlayer(victim))
		return Plugin_Continue;

	if (!IsClientDetectorActive(victim))
		return Plugin_Continue;

	if (!IsTrackedRocket(inflictor))
		return Plugin_Continue;

	int owner = g_iRocketOwner[inflictor];
	if (owner != victim || !IsHumanPlayer(owner))
		return Plugin_Continue;

	if (g_bRocketDamageChecked[inflictor]) {
		if (!g_bRocketDamageBlocked[inflictor])
			return Plugin_Continue;

		damage = 0.0;
		return Plugin_Handled;
	}

	g_bRocketDamageChecked[inflictor] = true;
	// Damage proves the rocket reached its final explosion simulation step
	g_iRocketSimCount[inflictor]++;
	StoreRocketOrigin(inflictor);

	int tick = GetGameTickCount();
	int cmdAge;
	int simAge;
	GetRocketAges(owner, inflictor, cmdAge, simAge);
	int delta = cmdAge - simAge;
	if (delta != 0) {
		NotifyRocketDelta(owner, tick, cmdAge, simAge, delta);

		if (g_cvBlockDamage.BoolValue) {
			g_bRocketDamageBlocked[inflictor] = true;
			damage = 0.0;
			return Plugin_Handled;
		}
	} else if (g_bShowAllDeltas[owner]) {
		NotifyRocketDeltaDebug(owner, tick, cmdAge, simAge, delta);
	}

	return Plugin_Continue;
}

public void OnRocketSpawned(int entity)
{
	TrackRocket(entity);
}

void ConVarChanged_Enabled(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ResetAllState();
}

public Action Command_ToggleDelta(int client, int args)
{
	if (!IsHumanPlayer(client)) {
		ReplyToCommand(client, "[dd] This command can only be used in game.");
		return Plugin_Handled;
	}

	if (args >= 1) {
		char value[8];
		GetCmdArg(1, value, sizeof(value));
		g_bShowAllDeltas[client] = StringToInt(value) != 0;
	} else {
		g_bShowAllDeltas[client] = !g_bShowAllDeltas[client];
	}

	ReplyToCommand(client, "[dd] Showing all rocket deltas: %s.", g_bShowAllDeltas[client] ? "on" : "off");
	return Plugin_Handled;
}

public Action Command_ToggleDetector(int client, int args)
{
	if (!IsHumanPlayer(client)) {
		ReplyToCommand(client, "[dd] This command can only be used in game.");
		return Plugin_Handled;
	}

	if (args >= 1) {
		char value[8];
		GetCmdArg(1, value, sizeof(value));
		g_bDetectorEnabled[client] = StringToInt(value) != 0;
	} else {
		g_bDetectorEnabled[client] = !g_bDetectorEnabled[client];
	}

	if (!g_bDetectorEnabled[client]) {
		g_bInsideRunCmd[client] = false;
		ClearClientRockets(client);
	}

	ReplyToCommand(client, "[dd] Desync detector: %s.", g_bDetectorEnabled[client] ? "on" : "off");
	return Plugin_Handled;
}

public Action Command_ToggleDebugDetails(int client, int args)
{
	if (!IsHumanPlayer(client)) {
		ReplyToCommand(client, "[dd] This command can only be used in game.");
		return Plugin_Handled;
	}

	if (args >= 1) {
		char value[8];
		GetCmdArg(1, value, sizeof(value));
		g_bDebugDetails[client] = StringToInt(value) != 0;
	} else {
		g_bDebugDetails[client] = !g_bDebugDetails[client];
	}

	ReplyToCommand(client, "[dd] Detailed output: %s.", g_bDebugDetails[client] ? "on" : "off");
	return Plugin_Handled;
}

void TrackRocket(int entity)
{
	if (!IsValidProjectileEntity(entity))
		return;

	int owner = GetRocketOwner(entity);
	if (!IsHumanPlayer(owner))
		return;

	if (!IsClientDetectorActive(owner))
		return;

	int ref = EntIndexToEntRef(entity);
	if (ref == INVALID_ENT_REFERENCE)
		return;

	if (g_iRocketRef[entity] == ref)
		return;

	bool createdInsideCmd = g_bInsideRunCmd[owner];
	if (!createdInsideCmd)
		return;

	if (g_iRocketRef[entity] != INVALID_ENT_REFERENCE)
		ClearRocketSlot(entity);

	g_iRocketOwner[entity] = owner;
	g_iRocketRef[entity] = ref;
	g_iRocketCreatedCmd[entity] = g_iCmdSerial[owner];
	g_iRocketSimCount[entity] = 0;
	g_bRocketCreatedInsideCmd[entity] = createdInsideCmd;
	g_bRocketDamageChecked[entity] = false;
	g_bRocketDamageBlocked[entity] = false;
	AddRocketToLists(entity, owner);
	StoreRocketOrigin(entity);
}

void SampleAllRocketMovement()
{
	int entity = g_iFirstTrackedRocket;
	while (entity != INVALID_ROCKET_INDEX) {
		int next = g_iNextTrackedRocket[entity];
		SampleRocketMovement(entity);
		entity = next;
	}
}

void SampleClientRocketMovement(int client)
{
	int entity = g_iFirstClientRocket[client];
	while (entity != INVALID_ROCKET_INDEX) {
		int next = g_iNextClientRocket[entity];
		SampleRocketMovement(entity);
		entity = next;
	}
}

bool SampleRocketMovement(int entity)
{
	if (!IsTrackedRocket(entity)) {
		ClearRocketSlot(entity);
		return false;
	}

	float origin[3];
	GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", origin);

	if (!g_bRocketHasLastOrigin[entity]) {
		StoreRocketOriginVector(entity, origin);
		return false;
	}

	if (origin[0] == g_flRocketLastOrigin[entity][0]
		&& origin[1] == g_flRocketLastOrigin[entity][1]
		&& origin[2] == g_flRocketLastOrigin[entity][2]) {
		return false;
	}

	StoreRocketOriginVector(entity, origin);
	g_iRocketSimCount[entity]++;
	return true;
}

void StoreRocketOrigin(int entity)
{
	float origin[3];
	GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", origin);
	StoreRocketOriginVector(entity, origin);
}

void StoreRocketOriginVector(int entity, const float origin[3])
{
	g_flRocketLastOrigin[entity][0] = origin[0];
	g_flRocketLastOrigin[entity][1] = origin[1];
	g_flRocketLastOrigin[entity][2] = origin[2];
	g_bRocketHasLastOrigin[entity] = true;
}

void NotifyRocketDelta(int client, int tick, int cmdAge, int simAge, int delta)
{
	char deltaText[16];
	FormatSignedDelta(delta, deltaText, sizeof(deltaText));
	PlayDesyncSound(client);

	if (g_bDebugDetails[client]) {
		Notify(client, "[dd] desync at tick %d (%s, c%d/s%d).",
			tick,
			deltaText,
			cmdAge,
			simAge);
	} else {
		Notify(client, "[dd] desync at tick %d (%s).", tick, deltaText);
	}
}

void NotifyRocketDeltaDebug(int client, int tick, int cmdAge, int simAge, int delta)
{
	char deltaText[16];
	FormatSignedDelta(delta, deltaText, sizeof(deltaText));

	if (g_bDebugDetails[client]) {
		Notify(client, "[dd] delta at tick %d (%s, c%d/s%d).",
			tick,
			deltaText,
			cmdAge,
			simAge);
	} else {
		Notify(client, "[dd] delta at tick %d (%s).", tick, deltaText);
	}
}

void Notify(int client, const char[] format, any ...)
{
	if (!g_bDetectorEnabled[client])
		return;

	char message[256];
	VFormat(message, sizeof(message), format, 3);

	if (g_cvConsole.BoolValue)
		PrintToConsole(client, "%s", message);

	if (g_cvChat.BoolValue)
		PrintToChat(client, "%s", message);
}

void PrecacheDesyncSound()
{
	PrecacheSound(DESYNC_SOUND, true);
}

void PlayDesyncSound(int client)
{
	if (!g_cvSound.BoolValue || !g_bDetectorEnabled[client] || !IsClientInGame(client))
		return;

	EmitSoundToClient(client, DESYNC_SOUND);
}

void ResetAllState()
{
	g_iFirstTrackedRocket = INVALID_ROCKET_INDEX;
	for (int client = 0; client <= MAXPLAYERS; client++)
		g_iFirstClientRocket[client] = INVALID_ROCKET_INDEX;

	for (int client = 1; client <= MaxClients; client++) {
		g_iCmdSerial[client] = 0;
		g_iCmdTickBaseBefore[client] = 0;
		g_bInsideRunCmd[client] = false;
		g_bDetectorEnabled[client] = true;
		g_bShowAllDeltas[client] = false;
		g_bDebugDetails[client] = false;
	}

	for (int entity = 0; entity < MAX_EDICTS; entity++)
		ResetRocketSlot(entity);
}

void ClearRocketSlot(int entity)
{
	if (!(0 <= entity < MAX_EDICTS))
		return;

	if (g_iRocketRef[entity] != INVALID_ENT_REFERENCE)
		RemoveRocketFromLists(entity);

	ResetRocketSlot(entity);
}

void ResetRocketSlot(int entity)
{
	g_iRocketOwner[entity] = 0;
	g_iRocketRef[entity] = INVALID_ENT_REFERENCE;
	g_iRocketCreatedCmd[entity] = 0;
	g_iRocketSimCount[entity] = 0;
	g_flRocketLastOrigin[entity][0] = 0.0;
	g_flRocketLastOrigin[entity][1] = 0.0;
	g_flRocketLastOrigin[entity][2] = 0.0;
	g_bRocketCreatedInsideCmd[entity] = false;
	g_bRocketDamageChecked[entity] = false;
	g_bRocketDamageBlocked[entity] = false;
	g_bRocketHasLastOrigin[entity] = false;
	g_iNextTrackedRocket[entity] = INVALID_ROCKET_INDEX;
	g_iPrevTrackedRocket[entity] = INVALID_ROCKET_INDEX;
	g_iNextClientRocket[entity] = INVALID_ROCKET_INDEX;
	g_iPrevClientRocket[entity] = INVALID_ROCKET_INDEX;
}

void ClearClientRockets(int client)
{
	int entity = g_iFirstClientRocket[client];
	while (entity != INVALID_ROCKET_INDEX) {
		int next = g_iNextClientRocket[entity];
		ClearRocketSlot(entity);
		entity = next;
	}
}

void AddRocketToLists(int entity, int owner)
{
	g_iPrevTrackedRocket[entity] = INVALID_ROCKET_INDEX;
	g_iNextTrackedRocket[entity] = g_iFirstTrackedRocket;
	if (g_iFirstTrackedRocket != INVALID_ROCKET_INDEX)
		g_iPrevTrackedRocket[g_iFirstTrackedRocket] = entity;
	g_iFirstTrackedRocket = entity;

	g_iPrevClientRocket[entity] = INVALID_ROCKET_INDEX;
	g_iNextClientRocket[entity] = g_iFirstClientRocket[owner];
	if (g_iFirstClientRocket[owner] != INVALID_ROCKET_INDEX)
		g_iPrevClientRocket[g_iFirstClientRocket[owner]] = entity;
	g_iFirstClientRocket[owner] = entity;
}

void RemoveRocketFromLists(int entity)
{
	int next = g_iNextTrackedRocket[entity];
	int prev = g_iPrevTrackedRocket[entity];
	if (prev != INVALID_ROCKET_INDEX)
		g_iNextTrackedRocket[prev] = next;
	else if (g_iFirstTrackedRocket == entity)
		g_iFirstTrackedRocket = next;

	if (next != INVALID_ROCKET_INDEX)
		g_iPrevTrackedRocket[next] = prev;

	int owner = g_iRocketOwner[entity];
	next = g_iNextClientRocket[entity];
	prev = g_iPrevClientRocket[entity];
	if (1 <= owner <= MaxClients) {
		if (prev != INVALID_ROCKET_INDEX)
			g_iNextClientRocket[prev] = next;
		else if (g_iFirstClientRocket[owner] == entity)
			g_iFirstClientRocket[owner] = next;

		if (next != INVALID_ROCKET_INDEX)
			g_iPrevClientRocket[next] = prev;
	}
}

bool IsRocketClass(const char[] classname)
{
	return StrEqual(classname, "tf_projectile_rocket")
		|| StrEqual(classname, "tf_projectile_energy_ball");
}

bool IsValidProjectileEntity(int entity)
{
	return entity > MaxClients
		&& entity < MAX_EDICTS
		&& IsValidEdict(entity);
}

bool IsHumanPlayer(int client)
{
	return 1 <= client <= MaxClients
		&& IsClientInGame(client)
		&& !IsFakeClient(client);
}

bool IsDetectorActive()
{
	return g_cvEnabled.BoolValue;
}

bool IsClientDetectorActive(int client)
{
	return 1 <= client <= MaxClients
		&& g_bDetectorEnabled[client]
		&& IsDetectorActive();
}

bool IsTrackedRocket(int entity)
{
	if (!IsValidProjectileEntity(entity))
		return false;

	int ref = g_iRocketRef[entity];
	return ref != INVALID_ENT_REFERENCE
		&& EntRefToEntIndex(ref) == entity;
}

void GetRocketAges(int owner, int entity, int &cmdAge, int &simAge)
{
	cmdAge = g_iCmdSerial[owner] - g_iRocketCreatedCmd[entity];
	simAge = g_iRocketSimCount[entity];
}

void FormatSignedDelta(int value, char[] buffer, int maxlen)
{
	if (value >= 0)
		Format(buffer, maxlen, "+%d", value);
	else
		Format(buffer, maxlen, "%d", value);
}

int GetRocketOwner(int entity)
{
	if (!IsValidProjectileEntity(entity))
		return -1;

	int owner = -1;
	if (HasEntProp(entity, Prop_Data, "m_hOwnerEntity"))
		owner = GetEntPropEnt(entity, Prop_Data, "m_hOwnerEntity");

	if (owner == -1 && HasEntProp(entity, Prop_Send, "m_hOwnerEntity"))
		owner = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");

	if (owner == -1 && HasEntProp(entity, Prop_Send, "m_hThrower"))
		owner = GetEntPropEnt(entity, Prop_Send, "m_hThrower");

	return owner;
}
