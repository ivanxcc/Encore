// Search and My List.
import { useEffect, useRef, useState } from "preact/hooks";
import { search, type CatalogRef, type Meta } from "../lib/api";
import { myList } from "../lib/library";
import { PosterCard, Shelf } from "./shared";
import { Search as SearchIcon, Stack } from "./icons";

let lastQuery = "";

export function SearchPage() {
  const [query, setQuery] = useState(lastQuery);
  const [results, setResults] = useState<{ ref: CatalogRef; metas: Meta[] }[]>([]);
  const [busy, setBusy] = useState(false);
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => { if (matchMedia("(pointer: fine)").matches) input.current?.focus(); }, []);
  useEffect(() => {
    lastQuery = query;
    const q = query.trim();
    if (q.length < 2) { setResults([]); setBusy(false); return; }
    const control = new AbortController();
    setBusy(true);
    // Just long enough not to search for every letter of a word typed quickly.
    const timer = setTimeout(() => {
      search(q, (partial) => { if (!control.signal.aborted) setResults(partial); }, control.signal)
        .finally(() => { if (!control.signal.aborted) setBusy(false); });
    }, 220);
    return () => { control.abort(); clearTimeout(timer); };
  }, [query]);

  const q = query.trim();
  return (
    <div class="page padded">
      <label class="search-field glass">
        <SearchIcon />
        <input ref={input} value={query} onInput={(e) => setQuery((e.target as HTMLInputElement).value)} placeholder="Movies, shows, and more"
          type="search" enterkeyhint="search" autocomplete="off" autocapitalize="off" spellcheck={false} aria-label="Search" />
      </label>
      {results.length > 0 ? (
        <div class="shelves" style={{ paddingTop: 0 }}>
          {results.map((r) => <Shelf key={r.ref.key} title={r.ref.title}>{r.metas.slice(0, 40).map((m) => <PosterCard key={m.id} meta={m} />)}</Shelf>)}
        </div>
      ) : (
        <div class="empty">
          <SearchIcon />
          <b>{q.length < 2 ? "Search" : busy ? "Searching…" : "No results"}</b>
          <span>{q.length < 2 ? "Find movies and shows across your add-ons." : busy ? "" : "Try a different title."}</span>
        </div>
      )}
    </div>
  );
}

export function ListPage() {
  const list = myList.value;
  return (
    <div class="page padded">
      <h1 class="heading">My List</h1>
      {list.length ? (
        <div class="grid">{list.map((i) => <PosterCard key={i._id} meta={{ id: i._id, type: i.type, name: i.name, poster: i.poster }} />)}</div>
      ) : (
        <div class="empty"><Stack /><b>Your list is empty</b><span>Add movies and shows with the + button and they'll appear here, and in the Encore apps.</span></div>
      )}
    </div>
  );
}
