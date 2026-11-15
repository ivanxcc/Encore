// Who's watching and what they've watched: profiles from Encore Cloud, the owner's library from the
// Stremio account, other profiles' libraries from the household.
import { signal, computed } from "@preact/signals";
import { auth, profileId } from "./core";
import { stremio, encore, type Household, type LibraryItem, type Meta, type Profile, type Video } from "./api";

export const household = signal<{ version: number; doc: Household } | null>(null);
/** The Stremio account's library (the owner profile's). */
const ownerItems = signal<LibraryItem[]>([]);
export const loaded = signal(false);

const OWNER: Profile = { id: "owner", name: "Me", isOwner: true, colorIndex: 0 };

export const profiles = computed<Profile[]>(() => household.value?.doc.profiles?.length ? household.value.doc.profiles : [OWNER]);
export const profile = computed<Profile | null>(() => profiles.value.find((p) => p.id === profileId.value) || null);

/** The active profile's library. */
export const items = computed<LibraryItem[]>(() => {
  const p = profile.value;
  if (!p || p.isOwner) return ownerItems.value;
  return household.value?.doc.libraries?.[p.id] || [];
});

const watchedKey = (p: Profile) => (p.isOwner ? "owner" : p.id);
export const watchedMarks = computed(() => {
  const p = profile.value;
  return (p && household.value?.doc.watched?.[watchedKey(p)]) || {};
});

export async function load() {
  if (!auth.value) return;
  try { ownerItems.value = JSON.parse(localStorage.getItem("encore.library") || "[]"); } catch {}
  try { household.value = JSON.parse(localStorage.getItem("encore.household") || "null"); } catch {}
  if (ownerItems.value.length) loaded.value = true;
  const [library, home] = await Promise.all([
    stremio<LibraryItem[]>("datastoreGet", { authKey: auth.value.key, collection: "libraryItem", ids: [], all: true }).catch(() => null),
    encore.household(),
  ]);
  if (library) {
    ownerItems.value = library.filter((i) => i && i._id && i.state);
    try { localStorage.setItem("encore.library", JSON.stringify(ownerItems.value)); } catch {}
  }
  if (home) {
    household.value = home;
    try { localStorage.setItem("encore.household", JSON.stringify(home)); } catch {}
  }
  loaded.value = true;
  // One profile and no PIN: straight in, as the apps do.
  if (!profile.value && profiles.value.length === 1 && !profiles.value[0].pinHash) profileId.value = profiles.value[0].id;
}

export const item = (id: string) => items.value.find((i) => i._id === id);

export function progressOf(i: LibraryItem): number {
  const d = i.state.duration || 0;
  return d > 0 ? Math.min(1, Math.max(0, (i.state.timeOffset || 0) / d)) : 0;
}
export const inProgress = (i: LibraryItem) => !i.removed && (i.state.timeOffset || 0) > 0 && progressOf(i) < 0.92;
/** Continue Watching is offering the next episode, not one partly watched. */
export const isUpNext = (i: LibraryItem) => (i.state.timeOffset || 0) > 0 && !(i.state.duration || 0);

export const continueWatching = computed(() => items.value.filter(inProgress)
  .sort((a, b) => String(b.state.lastWatched || "").localeCompare(String(a.state.lastWatched || ""))).slice(0, 30));
export const myList = computed(() => items.value.filter((i) => !i.removed && !i.temp)
  .sort((a, b) => String(b._mtime || "").localeCompare(String(a._mtime || ""))));

export function isWatched(videoId: string): boolean {
  return watchedMarks.value[videoId]?.watched === true;
}

/** "tt123:2:5" -> "S2, E5". */
export function episodeLabel(videoId: string | undefined): string | null {
  const parts = (videoId || "").split(":");
  return parts.length === 3 ? `S${parts[1]}, E${parts[2]}` : null;
}

// MARK: Writing

function blank(meta: Meta): LibraryItem {
  const now = new Date().toISOString();
  return { _id: meta.id, name: meta.name, type: meta.type, poster: meta.poster || "", removed: false, temp: true, _ctime: now, _mtime: now,
    state: { timeWatched: 0, timeOffset: 0, duration: 0, timesWatched: 0, flaggedWatched: 0 } };
}

let pending: LibraryItem | null = null;
let pendingMarks: Record<string, { watched: boolean; at: string }> = {};
let timer: number | undefined;

function change(meta: Meta, edit: (i: LibraryItem) => void) {
  const p = profile.value;
  if (!p) return;
  const next: LibraryItem = structuredClone(item(meta.id) || blank(meta));
  edit(next);
  next._mtime = new Date().toISOString();
  if (p.isOwner) {
    ownerItems.value = [...ownerItems.value.filter((i) => i._id !== next._id), next];
    try { localStorage.setItem("encore.library", JSON.stringify(ownerItems.value)); } catch {}
  } else if (household.value) {
    const doc = structuredClone(household.value.doc);
    doc.libraries = doc.libraries || {};
    doc.libraries[p.id] = [...(doc.libraries[p.id] || []).filter((i) => i._id !== next._id), next];
    household.value = { version: household.value.version, doc };
  }
  pending = next;
  clearTimeout(timer);
  timer = setTimeout(flush, 4000) as unknown as number;
}

/** Send what's changed: to Stremio for the owner; into the household for other profiles and for watched marks. */
export async function flush() {
  clearTimeout(timer);
  const p = profile.value, key = auth.value?.key;
  const next = pending, marks = pendingMarks;
  pending = null; pendingMarks = {};
  if (!p || !key || (!next && !Object.keys(marks).length)) return;
  if (next && p.isOwner) {
    stremio("datastorePut", { authKey: key, collection: "libraryItem", changes: [next] }).catch(() => { pending = pending || next; });
  }
  if ((next && !p.isOwner) || Object.keys(marks).length) {
    // The household is edited on the newest copy: only this profile's one item and marks are touched.
    for (let attempt = 0; attempt < 3; attempt++) {
      const latest = await encore.household();
      if (!latest) return;
      const doc = latest.doc;
      if (next && !p.isOwner) {
        doc.libraries = doc.libraries || {};
        const mine = (doc.libraries[p.id] || []).filter((i) => i._id !== next._id);
        doc.libraries[p.id] = [...mine, next].sort((a, b) => a._id.localeCompare(b._id));
      }
      if (Object.keys(marks).length) {
        doc.watched = doc.watched || {};
        doc.watched[watchedKey(p)] = { ...(doc.watched[watchedKey(p)] || {}), ...marks };
      }
      try {
        const saved = await encore.putHousehold(doc, latest.version);
        household.value = { version: saved.version, doc };
        return;
      } catch (e) {
        if ((e as { status?: number }).status !== 409) return;   // 409: someone else saved first; redo on their copy
      }
    }
  }
}

addEventListener("pagehide", () => { flush(); });

/** Record where playback is. Finishing (92%) marks it watched and lines up the next episode. */
export function recordProgress(meta: Meta, video: Video | undefined, position: number, duration: number, next?: Video) {
  if (!(duration > 0)) return;
  const finished = position / duration >= 0.92;
  const now = new Date().toISOString();
  const videoId = video?.id;
  change(meta, (i) => {
    if (i.state.video_id !== videoId) i.state.timeWatched = 0;
    i.state.video_id = videoId;
    i.state.timeOffset = Math.round(position * 1000);
    i.state.duration = Math.round(duration * 1000);
    i.state.lastWatched = now;
    i.removed = false;
    if (finished) {
      i.state.timesWatched = (i.state.timesWatched || 0) + 1;
      i.state.flaggedWatched = 1;
      i.state.timeOffset = 0;
      if (next && next.id !== videoId) {
        // The way Stremio's apps mark "next up": that episode, 1 ms in, no length yet.
        i.state.video_id = next.id;
        i.state.timeOffset = 1;
        i.state.duration = 0;
      }
    }
  });
  if (finished) {
    const id = videoId || meta.id;
    if (!isWatched(id)) {
      pendingMarks[id] = { watched: true, at: now.replace(/\.\d+Z$/, "Z") };
      const p = profile.value;
      if (p && household.value) {
        const doc = structuredClone(household.value.doc);
        doc.watched = doc.watched || {};
        doc.watched[watchedKey(p)] = { ...(doc.watched[watchedKey(p)] || {}), [id]: pendingMarks[id] };
        household.value = { version: household.value.version, doc };
      }
    }
  }
}

export function setInList(meta: Meta, inList: boolean) {
  change(meta, (i) => {
    i.temp = !inList;
    i.removed = !inList && !inProgress(i);
  });
  flush();
}

export async function pinMatches(p: Profile, pin: string): Promise<boolean> {
  if (!p.pinHash) return true;
  const hex = async (text: string) => [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)))].map((b) => b.toString(16).padStart(2, "0")).join("");
  return p.pinHash === await hex("encore.pin:" + pin) || p.pinHash === await hex(p.id.toUpperCase() + ":" + pin) || p.pinHash === await hex(p.id + ":" + pin);
}

export function signOut() {
  ownerItems.value = [];
  household.value = null;
  loaded.value = false;
}
