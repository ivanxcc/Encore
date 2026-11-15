import { render } from "preact";
import "./styles.css";
import { config } from "./lib/core";
import { App } from "./ui/app";

// The relay that serves this page says where Encore Cloud is; without it, sign-in is by email only.
fetch("/config.json").then((r) => r.json()).then((c) => { config.value = { cloud: c.cloud || "" }; }).catch(() => {})
  .finally(() => render(<App />, document.getElementById("app")!));
