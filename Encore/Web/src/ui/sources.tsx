// Sources: every release the account's add-ons found for a film or episode, Encore's choice first, to
// play one by hand (another language, a sharper or lighter copy).
import { useEffect, useRef, useState } from "preact/hooks";
import { go } from "../lib/core";
import type { Meta, Video } from "../lib/api";
import { languageName } from "../lib/lang";
import { chosenSource, sources, type Candidate } from "../lib/play";
import { Close } from "./icons";

export function SourcesSheet({ meta, video, title, onClose, onPick }: { meta: Meta; video?: Video; title: string; onClose: () => void; onPick?: (c: Candidate) => void }) {
  const [list, setList] = useState<Candidate[] | null>(null);
  const first = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    let live = true;
    sources(meta, video).then((l) => live && setList(l), () => live && setList([]));
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") { e.preventDefault(); onClose(); } };
    addEventListener("keydown", onKey);
    return () => { live = false; removeEventListener("keydown", onKey); };
  }, []);
  useEffect(() => { first.current?.focus({ preventScroll: true }); }, [list]);
  const play = (c: Candidate) => {
    if (onPick) { onClose(); onPick(c); return; }
    const key = video?.id || meta.id;
    chosenSource.set(key, c);
    onClose();
    go(`/watch/${meta.type}/${encodeURIComponent(meta.id)}${video ? `?v=${encodeURIComponent(video.id)}` : ""}`);
  };
  return (
    <>
      <div class="scrim dim" onClick={onClose} />
      <div class="sources glass" role="dialog" aria-label="Sources">
        <div class="sources-head">
          <div><b>Sources</b><small>{title}</small></div>
          <button class="icon" aria-label="Close" onClick={onClose}><Close /></button>
        </div>
        <div class="sources-list">
          {!list && <div class="sources-wait"><div class="spinner" /></div>}
          {list && !list.length && <p class="quiet" style={{ padding: "1rem" }}>None of your add-ons found a source for this.</p>}
          {list?.map((c, i) => (
            <button key={c.url} ref={i === 0 ? first : undefined} class="source" onClick={() => play(c)}>
              <span class="q">{c.quality || "—"}</span>
              <span class="words">
                <b>{i === 0 ? <><i class="best">Encore's choice</i>{c.name}</> : c.name || "Source"}</b>
                <small class="file">{c.label}</small>
                <span class="chips">
                  {c.cached ? <i class="ready">Ready</i> : <i class="slow">Not ready: downloads first</i>}
                  {c.size && <i>{c.size}</i>}
                  {c.langs.filter((l) => l !== "multi").slice(0, 4).map((l) => <i key={l}>{languageName(l)}</i>)}
                  {c.langs.includes("multi") && <i>Several languages</i>}
                  {c.hdr && <i>HDR</i>}
                  {c.hevc && <i>HEVC</i>}
                </span>
              </span>
            </button>
          ))}
        </div>
      </div>
    </>
  );
}
