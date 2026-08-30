import { GROUP_MEMBER_MAX, GROUP_MEMBER_MIN } from "@rakazo/contracts";
import { Stack, useLocalSearchParams, useRouter } from "expo-router";
import { useEffect, useState } from "react";
import { Alert, Pressable, ScrollView, Text, TextInput, View } from "react-native";
import { BotAvatar } from "../components/bot-avatar";
import {
  type MobileBot,
  type MobileGroupDetail,
  mobileGroupContextPresentation,
  rpc,
} from "../lib/api";

export default function GroupSettingsScreen() {
  const router = useRouter();
  const { groupId } = useLocalSearchParams<{ groupId: string }>();
  const [group, setGroup] = useState<MobileGroupDetail | null>(null);
  const [bots, setBots] = useState<MobileBot[]>([]);
  const [name, setName] = useState("");
  const [selected, setSelected] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState(false);
  const context = group ? mobileGroupContextPresentation(group) : null;

  useEffect(() => {
    if (!groupId) return;
    void Promise.all([
      rpc<MobileGroupDetail>("groups/get", { groupId }),
      rpc<MobileBot[]>("bots/list"),
    ])
      .then(([nextGroup, nextBots]) => {
        if (!nextGroup) throw new Error("Group not found");
        setGroup(nextGroup);
        setName(nextGroup.name);
        setSelected(nextGroup.members.map((member) => member.botId));
        setBots(nextBots.filter((bot) => !bot.archivedAt));
      })
      .catch((err) => setError(err instanceof Error ? err.message : "Could not load group"));
  }, [groupId]);

  function toggle(botId: string) {
    setSelected((current) => {
      if (current.includes(botId)) return current.filter((id) => id !== botId);
      if (current.length >= GROUP_MEMBER_MAX) return current;
      return [...current, botId];
    });
  }

  async function save() {
    if (!groupId || !group || pending) return;
    setPending(true);
    setError(null);
    try {
      const input: { groupId: string; name?: string; botIds?: string[] } = { groupId };
      if (name.trim() !== group.name) input.name = name.trim();
      const memberIds = group.members.map((member) => member.botId).join(",");
      if (selected.join(",") !== memberIds) input.botIds = selected;
      if (input.name || input.botIds) await rpc("groups/update", input);
      router.back();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not save group");
    } finally {
      setPending(false);
    }
  }

  function remove() {
    if (!groupId || !group) return;
    Alert.alert(group.name, "Delete this group? Bots and their solo threads are kept.", [
      { text: "Cancel", style: "cancel" },
      {
        text: "Delete",
        style: "destructive",
        onPress: () =>
          void rpc("groups/remove", { groupId })
            .then(() => router.replace("/"))
            .catch((err) =>
              Alert.alert(
                "Could not delete group",
                err instanceof Error ? err.message : "Try again.",
              ),
            ),
      },
    ]);
  }

  return (
    <>
      <Stack.Screen options={{ title: "Group settings" }} />
      <ScrollView
        style={{ flex: 1, backgroundColor: "#050506" }}
        contentContainerStyle={{ padding: 24 }}
      >
        <Text style={{ color: "#85858A", fontSize: 14 }}>Name</Text>
        <TextInput
          value={name}
          onChangeText={setName}
          placeholder="Group name"
          placeholderTextColor="#6C6C70"
          style={{
            marginTop: 8,
            backgroundColor: "#1A1A1D",
            borderRadius: 11,
            padding: 14,
            color: "#ECECEE",
            fontSize: 16,
          }}
        />
        <Text style={{ color: "#85858A", fontSize: 14, marginTop: 20 }}>
          Members ({GROUP_MEMBER_MIN}–{GROUP_MEMBER_MAX})
        </Text>
        {bots.map((bot) => {
          const checked = selected.includes(bot.id);
          return (
            <Pressable
              key={bot.id}
              onPress={() => toggle(bot.id)}
              style={{ flexDirection: "row", alignItems: "center", gap: 12, paddingVertical: 12 }}
            >
              <BotAvatar color={bot.color} identity={bot.id} size={34} status={bot.status} />
              <Text style={{ flex: 1, color: "#ECECEE", fontSize: 16 }}>{bot.name}</Text>
              <Text style={{ color: "#6C6C70" }}>{checked ? "✓" : ""}</Text>
            </Pressable>
          );
        })}
        {group && context && (group.creatorBotId || group.sharedContext || group.creatorContext) ? (
          <View
            style={{
              marginTop: 20,
              borderWidth: 1,
              borderColor: "#26262A",
              borderRadius: 14,
              backgroundColor: "#121214",
              padding: 16,
              gap: 16,
            }}
          >
            <ReadOnlyContext label="Created by" text={context.creatorName} />
            <ReadOnlyContext label="Shared starting context" text={context.sharedContext} />
            <ReadOnlyContext label="Creator-only starting context" text={context.creatorContext} />
          </View>
        ) : null}
        {error ? <Text style={{ color: "#FF6B6B", marginTop: 12 }}>{error}</Text> : null}
        <Pressable
          onPress={() => void save()}
          disabled={
            !name.trim() ||
            selected.length < GROUP_MEMBER_MIN ||
            selected.length > GROUP_MEMBER_MAX ||
            pending
          }
          style={{
            marginTop: 24,
            backgroundColor: "#8B5CF6",
            opacity:
              !name.trim() ||
              selected.length < GROUP_MEMBER_MIN ||
              selected.length > GROUP_MEMBER_MAX ||
              pending
                ? 0.5
                : 1,
            borderRadius: 11,
            padding: 14,
            alignItems: "center",
          }}
        >
          <Text style={{ color: "#FFF", fontSize: 16, fontWeight: "600" }}>
            {pending ? "Saving…" : "Save"}
          </Text>
        </Pressable>
        <Pressable
          onPress={remove}
          style={{
            marginTop: 16,
            borderRadius: 11,
            borderWidth: 1,
            borderColor: "#3A2020",
            padding: 14,
            alignItems: "center",
          }}
        >
          <Text style={{ color: "#FF6B6B", fontSize: 16 }}>Delete group</Text>
        </Pressable>
      </ScrollView>
    </>
  );
}

function ReadOnlyContext({ label, text }: { label: string; text: string }) {
  return (
    <View>
      <Text style={{ color: "#85858A", fontSize: 14 }}>{label}</Text>
      <Text
        selectable
        style={{
          marginTop: 6,
          color: "#C9C9CE",
          backgroundColor: "#1A1A1D",
          borderRadius: 10,
          padding: 12,
          fontSize: 14,
          lineHeight: 21,
        }}
      >
        {text}
      </Text>
    </View>
  );
}
