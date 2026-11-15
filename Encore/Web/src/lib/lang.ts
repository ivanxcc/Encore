// Languages: names for the codes files and add-ons use (ISO 639-2, three letters, sometimes two).
export const LANGUAGES: [string, string][] = [
  ["en", "English"], ["es", "Spanish"], ["fr", "French"], ["de", "German"], ["it", "Italian"], ["pt", "Portuguese"],
  ["nl", "Dutch"], ["sv", "Swedish"], ["no", "Norwegian"], ["da", "Danish"], ["fi", "Finnish"], ["pl", "Polish"],
  ["ru", "Russian"], ["uk", "Ukrainian"], ["tr", "Turkish"], ["ar", "Arabic"], ["he", "Hebrew"], ["hi", "Hindi"],
  ["ja", "Japanese"], ["ko", "Korean"], ["zh", "Chinese"], ["vi", "Vietnamese"], ["th", "Thai"], ["id", "Indonesian"],
  ["cs", "Czech"], ["el", "Greek"], ["hu", "Hungarian"], ["ro", "Romanian"], ["bg", "Bulgarian"], ["hr", "Croatian"],
  ["sr", "Serbian"], ["sk", "Slovak"], ["sl", "Slovenian"], ["fa", "Persian"], ["ms", "Malay"], ["tl", "Filipino"],
];

const THREE: Record<string, string> = {
  eng: "en", spa: "es", fre: "fr", fra: "fr", ger: "de", deu: "de", ita: "it", por: "pt", pob: "pt", dut: "nl", nld: "nl",
  swe: "sv", nor: "no", nob: "no", nno: "no", dan: "da", fin: "fi", pol: "pl", rus: "ru", ukr: "uk", tur: "tr", ara: "ar",
  heb: "he", hin: "hi", jpn: "ja", kor: "ko", chi: "zh", zho: "zh", vie: "vi", tha: "th", ind: "id", cze: "cs", ces: "cs",
  gre: "el", ell: "el", hun: "hu", rum: "ro", ron: "ro", bul: "bg", hrv: "hr", scc: "sr", srp: "sr", slo: "sk", slk: "sk",
  slv: "sl", per: "fa", fas: "fa", may: "ms", msa: "ms", fil: "tl", tgl: "tl", spl: "es", spn: "es", ze: "zh",
};

/** "spa", "es", "es-419", "Spanish" -> "es"; "" when unknown or undetermined. */
export function lang2(code?: string): string {
  if (!code) return "";
  const c = code.toLowerCase().trim();
  if (THREE[c]) return THREE[c];
  const two = c.split(/[-_]/)[0];
  if (two.length === 2) return two;
  const named = LANGUAGES.find(([, name]) => name.toLowerCase() === c);
  return named ? named[0] : "";
}

/** The language's name, for a code of any kind. */
export function languageName(code?: string): string {
  const two = lang2(code);
  return LANGUAGES.find(([c]) => c === two)?.[1] || (code && code !== "und" ? code.toUpperCase() : "Unknown");
}
