// Icons, drawn inline so they take the text colour and cost no requests.
const svg = (d: string, fill = false) => () => (
  <svg viewBox="0 0 24 24" fill={fill ? "currentColor" : "none"} stroke={fill ? "none" : "currentColor"} stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={d} /></svg>
);

export const Play = svg("M7 4.5v15a1 1 0 0 0 1.5.86l12.5-7.5a1 1 0 0 0 0-1.72L8.5 3.64A1 1 0 0 0 7 4.5z", true);
export const Pause = svg("M7 4h3.5v16H7zM13.5 4H17v16h-3.5z", true);
export const Plus = svg("M12 5v14M5 12h14");
export const Check = svg("M5 12.5l4.5 4.5L19 7.5");
export const Left = svg("M15 5l-7 7 7 7");
export const Right = svg("M9 5l7 7-7 7");
export const Home = svg("M4 11l8-7 8 7v8a1 1 0 0 1-1 1h-4v-6h-6v6H5a1 1 0 0 1-1-1z");
export const Search = svg("M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM20 20l-4-4");
export const Stack = svg("M5 9h14a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1v-8a1 1 0 0 1 1-1zM7 5.5h10");
export const Close = svg("M6 6l12 12M18 6L6 18");
export const Lock = svg("M7 11V8a5 5 0 0 1 10 0v3M6 11h12v9H6z");
export const Swap = svg("M7 8h12l-3-3M17 16H5l3 3");
export const Exit = svg("M10 5H6a1 1 0 0 0-1 1v12a1 1 0 0 0 1 1h4M14 8l4 4-4 4M18 12H9");
export const Full = svg("M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5");
export const Small = svg("M9 4v5H4M15 4v5h5M9 20v-5H4M15 20v-5h5");
export const Pip = svg("M4 6h16v12H4zM12 12h6v4h-6z");
export const Cast = svg("M5 17h14a1 1 0 0 0 1-1V6a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1zM12 15l4 5H8z");
export const Sound = svg("M4 9.5v5h3.5L12 18V6L7.5 9.5zM15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11");
export const Muted = svg("M4 9.5v5h3.5L12 18V6L7.5 9.5zM16 9.5l5 5M21 9.5l-5 5");
/** Skip to the next: a play arrow up against a bar, as on every player's "next track". */
export const Next = svg("M5 5.2v13.6a.8.8 0 0 0 1.2.7l9.6-6.8a.8.8 0 0 0 0-1.4L6.2 4.5A.8.8 0 0 0 5 5.2zM17 5h2.2v14H17z", true);
export const More = () => (
  <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><circle cx="5.5" cy="12" r="1.9" /><circle cx="12" cy="12" r="1.9" /><circle cx="18.5" cy="12" r="1.9" /></svg>
);
export const Info = svg("M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 11v5.5M12 7.6v.1");
export const Eye = svg("M2.5 12s3.5-6.5 9.5-6.5S21.5 12 21.5 12s-3.5 6.5-9.5 6.5S2.5 12 2.5 12zM12 9.2a2.8 2.8 0 1 0 0 5.6 2.8 2.8 0 0 0 0-5.6z");
export const Gear = svg("M12 15.2a3.2 3.2 0 1 0 0-6.4 3.2 3.2 0 0 0 0 6.4zM19.4 13.5l1.6 1.2-1.8 3.1-1.9-.6a7.6 7.6 0 0 1-1.9 1.1L15 20.5h-3.6l-.4-2.2a7.6 7.6 0 0 1-1.9-1.1l-1.9.6-1.8-3.1 1.6-1.2a7.4 7.4 0 0 1 0-2.2L5.4 10.1l1.8-3.1 1.9.6A7.6 7.6 0 0 1 11 6.5l.4-2h3.6l.4 2a7.6 7.6 0 0 1 1.9 1.1l1.9-.6 1.8 3.1-1.6 1.2a7.4 7.4 0 0 1 0 2.2z");
export const Bubble = svg("M5 5h14a1.5 1.5 0 0 1 1.5 1.5v9A1.5 1.5 0 0 1 19 17h-8l-4.5 3.5V17H5a1.5 1.5 0 0 1-1.5-1.5v-9A1.5 1.5 0 0 1 5 5zM7.5 10h4M13.5 10h3M7.5 13h2.5M12 13h4.5");
export const List = svg("M9 6.5h11M9 12h11M9 17.5h11M4.5 6.5h.01M4.5 12h.01M4.5 17.5h.01");
export const Chart = svg("M4 20V10M10 20V4M16 20v-7M21 20H3");
export const Film = svg("M4 5h16v14H4zM8 5v14M16 5v14M4 9.5h4M4 14.5h4M16 9.5h4M16 14.5h4");

export const Back10 = () => (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <path d="M12 5a8 8 0 1 1-7.4 5" /><path d="M12 1.8L8.6 5 12 8.2" /><text x="12" y="16.2" font-size="7.5" font-weight="700" text-anchor="middle" fill="currentColor" stroke="none" font-family="system-ui">10</text>
  </svg>
);
export const Fwd10 = () => (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <path d="M12 5a8 8 0 1 0 7.4 5" /><path d="M12 1.8L15.4 5 12 8.2" /><text x="12" y="16.2" font-size="7.5" font-weight="700" text-anchor="middle" fill="currentColor" stroke="none" font-family="system-ui">10</text>
  </svg>
);
