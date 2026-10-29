const { compareText } = core;
const months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const currencySymbols = { AUD: "A$", BRL: "R$", CAD: "CA$", CNY: "CN¥", EUR: "€", GBP: "£", HKD: "HK$", ILS: "₪", INR: "₹", JPY: "¥", KRW: "₩", MXN: "MX$", NZD: "NZ$", PHP: "₱", TWD: "NT$", USD: "$", VND: "₫" };
const currencyNames = { EUR: "euros", GBP: "British pounds", JPY: "Japanese yen", USD: "US dollars" };
const unitNames = { byte: ["byte", "byte", "B"], kilobyte: ["kB", "kilobyte", "kB"], megabyte: ["MB", "megabyte", "MB"], gigabyte: ["GB", "gigabyte", "GB"], terabyte: ["TB", "terabyte", "TB"], millisecond: ["ms", "millisecond", "ms"], second: ["sec", "second", "s"], minute: ["min", "minute", "m"], hour: ["hr", "hour", "h"], day: ["day", "day", "d"], week: ["wk", "week", "w"], month: ["mth", "month", "m"], year: ["yr", "year", "y"], meter: ["m", "meter", "m"], kilometer: ["km", "kilometer", "km"], mile: ["mi", "mile", "mi"], kilogram: ["kg", "kilogram", "kg"], gram: ["g", "gram", "g"], liter: ["L", "liter", "L"], celsius: ["°C", "degree Celsius", "°C"], fahrenheit: ["°F", "degree Fahrenheit", "°F"], percent: ["%", "percent", "%"], "kilometer-per-hour": ["km/h", "kilometer per hour", "km/h"], "mile-per-hour": ["mph", "mile per hour", "mph"] };
const zeroDecimalCurrencies = ["CLP", "ISK", "JPY", "KRW", "VND"];
const localeList = (locales) => locales === undefined ? [] : [].concat(locales).map(String);
const intlZone = (zone) => {
  if (zone !== undefined && !/^(utc|gmt|etc\/(utc|gmt|universal|zulu)|universal|zulu|z)$/i.test(String(zone))) throw new RangeError("Intl in Code Mode cells supports only the UTC time zone, not " + zone + ": shift the Date by the zone's offset yourself");
};
class NumberFormat {
  #options;
  constructor(locales, options = {}) {
    const style = options.style ?? "decimal";
    if (style === "currency" && !options.currency) throw new TypeError("Currency code is required with currency style.");
    const currency = options.currency === undefined ? undefined : String(options.currency).toUpperCase();
    const compact = options.notation === "compact";
    const digits = style === "currency" ? (zeroDecimalCurrencies.includes(currency) ? 0 : 2) : 0;
    const fallbackMax = style === "currency" ? digits : style === "percent" || compact ? 0 : 3;
    let min = options.minimumFractionDigits, max = options.maximumFractionDigits;
    if (min === undefined && max === undefined) { min = digits; max = fallbackMax; }
    else if (min === undefined) min = Math.min(digits, max);
    else if (max === undefined) max = Math.max(min, fallbackMax);
    if (min > max || min < 0 || max > 100) throw new RangeError("maximumFractionDigits value is out of range.");
    this.#options = { locale: localeList(locales)[0] ?? "en-US", numberingSystem: "latn", style, currency, currencyDisplay: options.currencyDisplay ?? "symbol", currencySign: options.currencySign ?? "standard", unit: options.unit, unitDisplay: options.unitDisplay ?? "short", minimumIntegerDigits: options.minimumIntegerDigits ?? 1, minimumFractionDigits: min, maximumFractionDigits: max, minimumSignificantDigits: options.minimumSignificantDigits, maximumSignificantDigits: options.maximumSignificantDigits, useGrouping: options.useGrouping ?? (compact ? "min2" : "auto"), notation: options.notation ?? "standard", compactDisplay: options.compactDisplay ?? "short", signDisplay: options.signDisplay ?? "auto", automatic: compact && options.minimumFractionDigits === undefined && options.maximumFractionDigits === undefined && options.maximumSignificantDigits === undefined };
  }
  format(value) { return this.formatToParts(value).map((part) => part.value).join(""); }
  formatToParts(value) {
    const o = this.#options;
    const parts = [];
    let negative, integer, fraction = "", suffix = "";
    if (typeof value === "bigint" && o.style !== "percent" && o.notation === "standard") {
      negative = value < 0n;
      integer = (negative ? -value : value).toString();
      fraction = "0".repeat(o.minimumFractionDigits);
    } else {
      let number = Number(value);
      if (Number.isNaN(number)) return [{ type: "nan", value: "NaN" }];
      if (o.style === "percent") number *= 100;
      negative = number < 0 || Object.is(number, -0);
      let x = Math.abs(number);
      if (o.notation === "compact") for (const [limit, short, long] of [[1e12, "T", " trillion"], [1e9, "B", " billion"], [1e6, "M", " million"], [1e3, "K", " thousand"]]) if (x >= limit) { x /= limit; suffix = o.compactDisplay === "long" ? long : short; break; }
      let digits;
      if (!Number.isFinite(x)) digits = "∞";
      else if (o.maximumSignificantDigits !== undefined || o.minimumSignificantDigits !== undefined) {
        digits = x === 0 ? "0" : String(Number(x.toPrecision(o.maximumSignificantDigits ?? 21)));
        const significant = digits.replace(".", "").replace(/^0+/, "").length;
        const wanted = o.minimumSignificantDigits ?? 1;
        if (significant < wanted) digits += (digits.includes(".") ? "" : ".") + "0".repeat(wanted - significant);
      } else {
        const max = o.automatic ? (x < 1 ? 2 : x < 10 ? 1 : 0) : o.maximumFractionDigits;
        const min = o.automatic ? 0 : o.minimumFractionDigits;
        digits = x >= 1e21 ? BigInt(Math.round(x)).toString() : Number(Math.round(Number(x + "e" + max)) + "e-" + max).toFixed(max);
        if (max > min && digits.includes(".")) digits = digits.replace(new RegExp("\\.?0{1," + (max - min) + "}$"), "");
      }
      [integer, fraction = ""] = digits.split(".");
    }
    if (integer !== "∞") integer = integer.padStart(o.minimumIntegerDigits, "0");
    const zero = /^0*$/.test(integer + fraction);
    const sign = o.signDisplay === "never" ? "" : negative && !(o.signDisplay === "exceptZero" && zero) && !(o.signDisplay === "negative" && zero) ? "-" : (o.signDisplay === "always" || (o.signDisplay === "exceptZero" && !zero)) ? "+" : "";
    const accounting = o.style === "currency" && o.currencySign === "accounting" && sign === "-";
    if (accounting) parts.push({ type: "literal", value: "(" });
    else if (sign) parts.push({ type: sign === "-" ? "minusSign" : "plusSign", value: sign });
    if (o.style === "currency" && o.currencyDisplay !== "name") {
      const symbol = o.currencyDisplay === "code" ? o.currency + "\u00a0" : o.currencyDisplay === "narrowSymbol" ? (currencySymbols[o.currency] ?? o.currency + "\u00a0").replace(/^[A-Z]+(?=\W)/, "") : currencySymbols[o.currency] ?? o.currency + "\u00a0";
      parts.push({ type: "currency", value: symbol });
    }
    if (integer === "∞") parts.push({ type: "infinity", value: "∞" });
    else {
      const grouped = o.useGrouping !== false && (o.useGrouping !== "min2" || integer.length >= 5);
      const groups = grouped ? integer.replace(/\B(?=(\d{3})+(?!\d))/g, ",").split(",") : [integer];
      groups.forEach((group, index) => { if (index) parts.push({ type: "group", value: "," }); parts.push({ type: "integer", value: group }); });
      if (fraction) parts.push({ type: "decimal", value: "." }, { type: "fraction", value: fraction });
    }
    if (suffix) parts.push({ type: "compact", value: suffix.trim() === suffix ? suffix : suffix });
    if (o.style === "percent") parts.push({ type: "percentSign", value: "%" });
    if (o.style === "currency" && o.currencyDisplay === "name") parts.push({ type: "literal", value: " " }, { type: "currency", value: currencyNames[o.currency] ?? o.currency });
    if (o.style === "unit" && o.unit) {
      const names = unitNames[o.unit] ?? [o.unit, o.unit, o.unit];
      const plural = !(integer === "1" && !fraction);
      const label = o.unitDisplay === "long" ? names[1] + (plural && !/^(kB|MB|GB|TB)$/.test(names[1]) ? "s" : "") : o.unitDisplay === "narrow" ? names[2] : names[0] === "day" && plural ? "days" : names[0];
      parts.push({ type: "literal", value: o.unitDisplay === "narrow" || label === "%" || label.startsWith("°") ? "" : " " }, { type: "unit", value: label });
    }
    if (accounting) parts.push({ type: "literal", value: ")" });
    return parts;
  }
  formatRange(start, end) { return this.format(start) + "–" + this.format(end); }
  resolvedOptions() { const { automatic, ...options } = this.#options; return options; }
  static supportedLocalesOf(locales) { return localeList(locales); }
}
const dateFields = ["weekday", "era", "year", "month", "day"];
const timeFields = ["hour", "minute", "second", "fractionalSecondDigits", "dayPeriod"];
const hasAny = (options, fields) => fields.some((field) => options[field] !== undefined);
const expandStyles = (options) => {
  const o = { ...options };
  delete o.dateStyle;
  delete o.timeStyle;
  if (options.dateStyle === "full") Object.assign(o, { weekday: "long", month: "long", day: "numeric", year: "numeric" });
  if (options.dateStyle === "long") Object.assign(o, { month: "long", day: "numeric", year: "numeric" });
  if (options.dateStyle === "medium") Object.assign(o, { month: "short", day: "numeric", year: "numeric" });
  if (options.dateStyle === "short") Object.assign(o, { month: "numeric", day: "numeric", year: "2-digit" });
  if (options.timeStyle) Object.assign(o, { hour: "numeric", minute: "2-digit" });
  if (options.timeStyle === "full" || options.timeStyle === "long" || options.timeStyle === "medium") o.second = "2-digit";
  if (options.timeStyle === "full") o.timeZoneName = "long";
  if (options.timeStyle === "long") o.timeZoneName = "short";
  o.joiner = options.timeStyle && (options.dateStyle === "full" || options.dateStyle === "long") ? " at " : ", ";
  return o;
};
class DateTimeFormat {
  #options;
  constructor(locales, options = {}) {
    intlZone(options.timeZone);
    const o = { ...options };
    if (!o.dateStyle && !o.timeStyle && !hasAny(o, [...dateFields, ...timeFields, "timeZoneName"])) Object.assign(o, { year: "numeric", month: "numeric", day: "numeric" });
    this.#options = { locale: localeList(locales)[0] ?? "en-US", ...o };
  }
  format(date) { return this.formatToParts(date).map((part) => part.value).join(""); }
  formatToParts(date) {
    const d = date === undefined ? new Date() : new Date(date instanceof Date ? date.getTime() : date);
    if (Number.isNaN(d.getTime())) throw new RangeError("Invalid time value");
    const o = this.#options.dateStyle || this.#options.timeStyle ? expandStyles(this.#options) : this.#options;
    const parts = [];
    const literal = (value) => parts.push({ type: "literal", value });
    const put = (type, value) => parts.push({ type, value });
    const two = (value) => String(value).padStart(2, "0");
    const Y = d.getUTCFullYear(), M = d.getUTCMonth(), D = d.getUTCDate(), W = d.getUTCDay(), h = d.getUTCHours(), m = d.getUTCMinutes(), s = d.getUTCSeconds();
    const year = o.year === "2-digit" ? two(Y % 100) : String(Y);
    const day = o.day === "2-digit" ? two(D) : String(D);
    const textual = o.month === "long" || o.month === "short" || o.month === "narrow";
    const hasDate = Boolean(o.year || o.month || o.day);
    if (o.weekday) { put("weekday", o.weekday === "long" ? weekdays[W] : o.weekday === "short" ? weekdays[W].slice(0, 3) : weekdays[W][0]); if (hasDate) literal(", "); }
    if (textual) {
      put("month", o.month === "long" ? months[M] : o.month === "short" ? months[M].slice(0, 3) : months[M][0]);
      if (o.day) { literal(" "); put("day", day); }
      if (o.year) { literal(o.day ? ", " : " "); put("year", year); }
    } else if (hasDate) {
      const list = [];
      if (o.month) list.push(["month", o.month === "2-digit" ? two(M + 1) : String(M + 1)]);
      if (o.day) list.push(["day", day]);
      if (o.year) list.push(["year", year]);
      list.forEach(([type, value], index) => { if (index) literal("/"); put(type, value); });
    }
    if (o.hour || o.minute || o.second) {
      if (parts.length) literal(o.joiner ?? ", ");
      const twelve = o.hour12 !== undefined ? Boolean(o.hour12) : o.hourCycle ? o.hourCycle === "h12" || o.hourCycle === "h11" : true;
      const list = [];
      if (o.hour) { const hour = twelve ? h % 12 || 12 : h; list.push(["hour", o.hour === "2-digit" || !twelve ? two(hour) : String(hour)]); }
      if (o.minute) list.push(["minute", o.hour || o.minute === "2-digit" ? two(m) : String(m)]);
      if (o.second) list.push(["second", o.minute || o.second === "2-digit" ? two(s) : String(s)]);
      list.forEach(([type, value], index) => { if (index) literal(":"); put(type, value); });
      if (o.fractionalSecondDigits) { literal("."); put("fractionalSecond", String(d.getUTCMilliseconds()).padStart(3, "0").slice(0, o.fractionalSecondDigits)); }
      if (twelve && o.hour) { literal(" "); put("dayPeriod", h < 12 ? "AM" : "PM"); }
    }
    if (o.timeZoneName) { literal(parts.length ? " " : ""); put("timeZoneName", o.timeZoneName === "long" ? "Coordinated Universal Time" : "UTC"); }
    return parts;
  }
  formatRange(start, end) { return this.format(start) + " – " + this.format(end); }
  resolvedOptions() { return { calendar: "gregory", numberingSystem: "latn", timeZone: "UTC", ...this.#options }; }
  static supportedLocalesOf(locales) { return localeList(locales); }
}
class Collator {
  #options;
  constructor(locales, options = {}) { this.#options = { locale: localeList(locales)[0] ?? "en-US", usage: "sort", sensitivity: options.sensitivity ?? "variant", ignorePunctuation: Boolean(options.ignorePunctuation), numeric: Boolean(options.numeric), caseFirst: options.caseFirst ?? "false" }; this.compare = this.compare.bind(this); }
  compare(a, b) { return compareText(a, b, this.#options); }
  resolvedOptions() { return { ...this.#options }; }
  static supportedLocalesOf(locales) { return localeList(locales); }
}
class PluralRules {
  #options;
  constructor(locales, options = {}) { this.#options = { locale: localeList(locales)[0] ?? "en-US", type: options.type ?? "cardinal" }; }
  select(value) {
    const n = Math.abs(Number(value));
    if (this.#options.type === "ordinal") { const tens = n % 100, ones = n % 10; return ones === 1 && tens !== 11 ? "one" : ones === 2 && tens !== 12 ? "two" : ones === 3 && tens !== 13 ? "few" : "other"; }
    return n === 1 ? "one" : "other";
  }
  resolvedOptions() { return { ...this.#options, pluralCategories: this.#options.type === "ordinal" ? ["few", "one", "two", "other"] : ["one", "other"] }; }
  static supportedLocalesOf(locales) { return localeList(locales); }
}
class RelativeTimeFormat {
  #options;
  constructor(locales, options = {}) { this.#options = { locale: localeList(locales)[0] ?? "en-US", numeric: options.numeric ?? "always", style: options.style ?? "long" }; }
  format(value, unit) {
    const name = String(unit).replace(/s$/, "");
    if (!["second", "minute", "hour", "day", "week", "month", "quarter", "year"].includes(name)) throw new RangeError("Invalid unit argument for format() '" + unit + "'");
    const n = Number(value);
    if (this.#options.numeric === "auto") {
      if (name === "day" && Math.abs(n) <= 1) return n === -1 ? "yesterday" : n === 1 ? "tomorrow" : "today";
      if (name === "second" && n === 0) return "now";
      if (Math.abs(n) <= 1 && ["minute", "hour"].includes(name) && n === 0) return "this " + name;
      if (Math.abs(n) === 1 || n === 0) if (["week", "month", "quarter", "year"].includes(name)) return (n < 0 ? "last " : n > 0 ? "next " : "this ") + name;
    }
    const amount = Math.abs(n);
    const label = new NumberFormat("en-US").format(amount) + " " + name + (amount === 1 ? "" : "s");
    return n < 0 || Object.is(n, -0) ? label + " ago" : "in " + label;
  }
  formatToParts(value, unit) { return [{ type: "literal", value: this.format(value, unit) }]; }
  resolvedOptions() { return { ...this.#options, numberingSystem: "latn" }; }
  static supportedLocalesOf(locales) { return localeList(locales); }
}
class ListFormat {
  #options;
  constructor(locales, options = {}) { this.#options = { locale: localeList(locales)[0] ?? "en-US", type: options.type ?? "conjunction", style: options.style ?? "long" }; }
  format(list) {
    const items = [...list].map(String);
    const word = this.#options.type === "disjunction" ? "or" : this.#options.type === "unit" ? "" : this.#options.style === "long" ? "and" : "&";
    if (items.length < 2) return items.join("");
    if (!word) return items.join(this.#options.style === "narrow" ? " " : ", ");
    if (items.length === 2) return items[0] + " " + word + " " + items[1];
    return items.slice(0, -1).join(", ") + ", " + word + " " + items.at(-1);
  }
  formatToParts(list) { return [{ type: "literal", value: this.format(list) }]; }
  resolvedOptions() { return { ...this.#options }; }
  static supportedLocalesOf(locales) { return localeList(locales); }
}
class Segmenter {
  #options;
  constructor(locales, options = {}) { this.#options = { locale: localeList(locales)[0] ?? "en-US", granularity: options.granularity ?? "grapheme" }; }
  segment(input) {
    const text = String(input);
    const granularity = this.#options.granularity;
    const pattern = granularity === "word" ? /[\p{L}\p{N}_'’]+|\s+|[^\p{L}\p{N}_'’\s]/gu : granularity === "sentence" ? /[^.!?]+(?:[.!?]+|$)\s*|[.!?]+\s*/gu : /\p{Regional_Indicator}{2}|(?:\P{M}\p{M}*)(?:\u200d\P{M}\p{M}*)*/gu;
    const segments = [...text.matchAll(pattern)].map((match) => ({ segment: match[0], index: match.index, input: text, ...(granularity === "word" ? { isWordLike: /[\p{L}\p{N}]/u.test(match[0]) } : {}) }));
    return Object.assign(segments, { containing: (index = 0) => segments.find((entry) => index >= entry.index && index < entry.index + entry.segment.length) });
  }
  resolvedOptions() { return { ...this.#options }; }
  static supportedLocalesOf(locales) { return localeList(locales); }
}
class Locale {
  constructor(tag, options = {}) {
    const [language, ...rest] = String(tag).split(/[-_]/);
    this.language = language.toLowerCase();
    this.region = options.region ?? rest.find((part) => /^[A-Za-z]{2}$|^\d{3}$/.test(part))?.toUpperCase();
    this.script = options.script ?? rest.find((part) => /^[A-Za-z]{4}$/.test(part));
    this.baseName = [this.language, this.script, this.region].filter(Boolean).join("-");
  }
  maximize() { return this; }
  minimize() { return this; }
  toString() { return this.baseName; }
}
class DisplayNames {
  constructor(locales, options = {}) { this.options = { locale: localeList(locales)[0] ?? "en-US", type: options.type, fallback: options.fallback ?? "code" }; }
  of(code) { return this.options.type === "currency" ? currencyNames[String(code).toUpperCase()] ?? String(code) : String(code); }
  resolvedOptions() { return { ...this.options }; }
}
const callable = (Class) => {
  const wrapper = function (...args) { return new Class(...args); };
  wrapper.prototype = Class.prototype;
  wrapper.supportedLocalesOf = Class.supportedLocalesOf;
  Object.defineProperty(wrapper, "name", { value: Class.name });
  return wrapper;
};
const Intl = {
  Collator: callable(Collator), DateTimeFormat: callable(DateTimeFormat), DisplayNames, ListFormat, Locale, NumberFormat: callable(NumberFormat), PluralRules, RelativeTimeFormat, Segmenter,
  getCanonicalLocales: (locales) => localeList(locales),
  supportedValuesOf: (key) => ({ calendar: ["gregory"], currency: Object.keys(currencySymbols), numberingSystem: ["latn"], timeZone: ["UTC"], unit: Object.keys(unitNames) })[key] ?? [],
};
const localeDate = (date, locales, options, kind) => {
  if (Number.isNaN(date.getTime())) return "Invalid Date";
  const o = { ...(options ?? {}) };
  const dates = hasAny(o, dateFields) || o.dateStyle, times = hasAny(o, timeFields) || o.timeStyle;
  if (!dates && !times) {
    if (kind !== "time") Object.assign(o, { year: "numeric", month: "numeric", day: "numeric" });
    if (kind !== "date") Object.assign(o, { hour: "numeric", minute: "2-digit", second: "2-digit" });
  }
  return new DateTimeFormat(locales, o).format(date);
};
return { Intl, localeDate };
