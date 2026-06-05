#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "1.0"
#define MAX_EDICTS (1 << 11)
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
bool g_bInsideRunCmd[MAXPLAYERS + 1];
bool g_bDetectorEnabled[MAXPLAYERS + 1];
bool g_bShowAllDeltas[MAXPLAYERS + 1];
bool g_bDebugDetails[MAXPLAYERS + 1];
bool g_bJumpQoLLoaded;

int g_iRocketOwner[MAX_EDICTS];
int g_iRocketRef[MAX_EDICTS];
int g_iRocketCreatedCmd[MAX_EDICTS];
int g_iRocketCreatedTick[MAX_EDICTS];
bool g_bRocketCreatedInsideCmd[MAX_EDICTS];
bool g_bRocketDamageChecked[MAX_EDICTS];
bool g_bRocketDamageBlocked[MAX_EDICTS];

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("sm_desyncdetector_enabled", "1", "Enable desync detector.", _, true, 0.0, true, 1.0);
	g_cvChat = CreateConVar("sm_desyncdetector_chat", "1", "Print warnings to chat.", _, true, 0.0, true, 1.0);
	g_cvConsole = CreateConVar("sm_desyncdetector_console", "1", "Print warnings to the player's console.", _, true, 0.0, true, 1.0);
	g_cvBlockDamage = CreateConVar("sm_desyncdetector_block_damage", "0", "Block rocket damage when a desync is detected.", _, true, 0.0, true, 1.0);
	g_cvSound = CreateConVar("sm_desyncdetector_sound", "0", "Play a warning sound when a desync is detected.", _, true, 0.0, true, 1.0);
	g_cvEnabled.AddChangeHook(ConVarChanged_Enabled);
	g_bJumpQoLLoaded = LibraryExists("jumpqol");

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

public void OnClientDisconnect(int client)
{
	g_iCmdSerial[client] = 0;
	g_bInsideRunCmd[client] = false;
	g_bDetectorEnabled[client] = true;
	g_bShowAllDeltas[client] = false;
	g_bDebugDetails[client] = false;
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnClientTakeDamage);
}

public void OnLibraryAdded(const char[] name)
{
	if (!StrEqual(name, "jumpqol"))
		return;

	g_bJumpQoLLoaded = true;
	ResetAllState();
}

public void OnLibraryRemoved(const char[] name)
{
	if (!StrEqual(name, "jumpqol"))
		return;

	g_bJumpQoLLoaded = false;
	ResetAllState();
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (IsClientDetectorActive(client)) {
		g_iCmdSerial[client]++;
		g_bInsideRunCmd[client] = true;
	}

	return Plugin_Continue;
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
	g_bInsideRunCmd[client] = false;
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

	int tick = GetGameTickCount();
	int cmdAge;
	int tickAge;
	GetRocketAges(owner, inflictor, tick, cmdAge, tickAge);
	int delta = cmdAge - tickAge;
	if (delta != 0) {
		NotifyRocketDelta(owner, tick, cmdAge, tickAge, delta);

		if (g_cvBlockDamage.BoolValue) {
			g_bRocketDamageBlocked[inflictor] = true;
			damage = 0.0;
			return Plugin_Handled;
		}
	} else if (g_bShowAllDeltas[owner]) {
		NotifyRocketDeltaDebug(owner, tick, cmdAge, tickAge, delta);
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

	int tick = GetGameTickCount();
	bool createdInsideCmd = g_bInsideRunCmd[owner];
	if (!createdInsideCmd)
		return;

	g_iRocketOwner[entity] = owner;
	g_iRocketRef[entity] = ref;
	g_iRocketCreatedCmd[entity] = g_iCmdSerial[owner];
	g_iRocketCreatedTick[entity] = tick;
	g_bRocketCreatedInsideCmd[entity] = createdInsideCmd;
	g_bRocketDamageChecked[entity] = false;
	g_bRocketDamageBlocked[entity] = false;
}

void NotifyRocketDelta(int client, int tick, int cmdAge, int tickAge, int delta)
{
	char deltaText[16];
	FormatSignedDelta(delta, deltaText, sizeof(deltaText));
	PlayDesyncSound(client);

	if (g_bDebugDetails[client]) {
		Notify(client, "[dd] desync at tick %d (%s, c%d/s%d).",
			tick,
			deltaText,
			cmdAge,
			tickAge);
	} else {
		Notify(client, "[dd] desync at tick %d (%s).", tick, deltaText);
	}
}

void NotifyRocketDeltaDebug(int client, int tick, int cmdAge, int tickAge, int delta)
{
	char deltaText[16];
	FormatSignedDelta(delta, deltaText, sizeof(deltaText));

	if (g_bDebugDetails[client]) {
		Notify(client, "[dd] delta at tick %d (%s, c%d/s%d).",
			tick,
			deltaText,
			cmdAge,
			tickAge);
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
	for (int client = 1; client <= MaxClients; client++) {
		g_iCmdSerial[client] = 0;
		g_bInsideRunCmd[client] = false;
		g_bDetectorEnabled[client] = true;
		g_bShowAllDeltas[client] = false;
		g_bDebugDetails[client] = false;
	}

	for (int entity = 0; entity < MAX_EDICTS; entity++)
		ClearRocketSlot(entity);
}

void ClearRocketSlot(int entity)
{
	if (!(0 <= entity < MAX_EDICTS))
		return;

	g_iRocketOwner[entity] = 0;
	g_iRocketRef[entity] = INVALID_ENT_REFERENCE;
	g_iRocketCreatedCmd[entity] = 0;
	g_iRocketCreatedTick[entity] = 0;
	g_bRocketCreatedInsideCmd[entity] = false;
	g_bRocketDamageChecked[entity] = false;
	g_bRocketDamageBlocked[entity] = false;
}

void ClearClientRockets(int client)
{
	for (int entity = 0; entity < MAX_EDICTS; entity++) {
		if (g_iRocketOwner[entity] == client)
			ClearRocketSlot(entity);
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
	return g_cvEnabled.BoolValue
		&& !g_bJumpQoLLoaded;
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

void GetRocketAges(int owner, int entity, int currentTick, int &cmdAge, int &tickAge)
{
	cmdAge = g_iCmdSerial[owner] - g_iRocketCreatedCmd[entity];
	tickAge = currentTick - g_iRocketCreatedTick[entity];
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
