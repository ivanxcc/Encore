// What the player tells the server about its own plays: that one began (and how long the first frame
// took), how it's going, and when it was left. The server's owner sees it on the Admin page; it stays
// on that server. Reports never get in the way: a failed one is dropped.
import { relayToken } from "./core";

/** "iPad · Safari", "Mac · Chrome", "Tesla". */
export const device = (() => {
  const ua = navigator.userAgent;
  if (/Tesla|QtCarBrowser/i.test(ua)) return "Tesla";
  const kind = /iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1) ? "iPad"
    : /iPhone/.test(ua) ? "iPhone" : /Android/.test(ua) ? (/Mobile/.test(ua) ? "Android phone" : "Android tablet")
    : /Macintosh/.test(ua) ? "Mac" : /Windows/.test(ua) ? "Windows" : /CrOS/.test(ua) ? "Chromebook" : /Linux/.test(ua) ? "Linux" : "Browser";
  const browser = /Edg\//.test(ua) ? "Edge" : /CriOS|Chrome\//.test(ua) ? "Chrome" : /FxiOS|Firefox\//.test(ua) ? "Firefox" : /Safari\//.test(ua) ? "Safari" : "";
  const home = (navigator as Navigator & { standalone?: boolean }).standalone === true || matchMedia("(display-mode: standalone)").matches;
  return [kind, home ? "Home Screen" : browser].filter(Boolean).join(" · ");
})();

function send(body: object, beacon = false) {
  const token = relayToken.value?.value;
  if (!token) return;
  if (beacon && navigator.sendBeacon) {
    navigator.sendBeacon("/v1/report", new Blob([JSON.stringify({ ...body, token })], { type: "application/json" }));
    return;
  }
  fetch("/v1/report", { method: "POST", headers: { "content-type": "application/json", authorization: "Bearer " + token }, body: JSON.stringify(body), keepalive: true }).catch(() => {});
}

export interface PlayInfo { id: string; title: string; episode?: string; type: string; metaId: string; profile?: string; quality?: string; source?: string; mode: string; session?: string; startMs: number }
export interface PlayProgress { id: string; watched: number; stalls: number; errors: number; switches: number; seekMs?: number; mode?: string; session?: string; quality?: string; source?: string; problem?: string }

export const reportPlay = (p: PlayInfo) => send({ kind: "play", play: { ...p, device } });
export const reportProgress = (p: PlayProgress) => send({ kind: "update", play: p });
export const reportEnd = (p: PlayProgress) => send({ kind: "end", play: p }, true);
export const reportProblem = (what: string) => send({ kind: "problem", what });
export const reportProfiles = (profiles: { name: string; avatar?: string; kids?: boolean; pin?: boolean }[]) => send({ kind: "profiles", profiles, device });
