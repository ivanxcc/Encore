import { render } from "preact";
import "./styles.css";
import { config, pendingInvite } from "./lib/core";

// An invitation link (/join#…): keep the invitation for the sign-in, and show the app's own address.
if (location.pathname === "/join" && location.hash.length > 20) {
  pendingInvite.value = decodeURIComponent(location.hash.slice(1));
  history.replaceState(null, "", "/");
}
import { App, Offline } from "./ui/app";

// Keep the app's own files on the device: it opens at once, and opens without a connection.
if (import.meta.env.PROD && "serviceWorker" in navigator) {
  addEventListener("load", () => { navigator.serviceWorker.register("/sw.js").catch(() => {}); });
}

// The relay that serves this page says where Encore Cloud is; without it, sign-in is by email only.
fetch("/config.json").then((r) => r.json()).then((c) => { config.value = { cloud: c.cloud || "" }; }).catch(() => {})
  .finally(() => render(<><App /><Offline /></>, document.getElementById("app")!));
