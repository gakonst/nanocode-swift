var NanocodePython = (function(exports) {
	Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
	// src/bash/FileSystem.ts
	const messages = {
		ENOENT: "No such file or directory",
		EEXIST: "File exists",
		ENOTDIR: "Not a directory",
		EISDIR: "Is a directory",
		ENOTEMPTY: "Directory not empty",
		EFBIG: "File too large",
		EINVAL: "Invalid argument",
		ELOOP: "Too many levels of symbolic links",
		EROFS: "Read-only file system",
		EXDEV: "Invalid cross-device link",
		EBUSY: "Device or resource busy"
	};
	var FsError = class extends Error {
		name = "FileSystem.FsError";
		code;
		constructor(code, path) {
			super(`${path}: ${messages[code] ?? code}`);
			this.code = code;
		}
	};
	// src/bash/internal/Fs.ts
	const encoder = new TextEncoder();
	const strict = new TextDecoder("utf-8", {
		fatal: true,
		ignoreBOM: true
	});
	new TextDecoder("utf-8", {
		fatal: false,
		ignoreBOM: true
	});
	function wellFormed(text) {
		return text.isWellFormed();
	}
	function byte(value) {
		const b = value & 255;
		return String.fromCharCode(b < 128 ? b : 56320 + b);
	}
	function encode(text) {
		if (wellFormed(text)) return encoder.encode(text);
		const out = new Uint8Array(text.length * 3);
		let n = 0;
		for (let i = 0; i < text.length; i++) {
			let c = text.charCodeAt(i);
			if (c < 128) {
				out[n++] = c;
				continue;
			}
			if (c >= 56448 && c <= 56575) {
				out[n++] = c - 56320;
				continue;
			}
			if (c >= 55296 && c <= 56319) {
				const d = text.charCodeAt(i + 1);
				if (d >= 56320 && d <= 57343) {
					c = 65536 + (c - 55296 << 10) + (d - 56320);
					i++;
					out[n++] = 240 | c >> 18;
					out[n++] = 128 | c >> 12 & 63;
					out[n++] = 128 | c >> 6 & 63;
					out[n++] = 128 | c & 63;
					continue;
				}
				c = 65533;
			} else if (c >= 56320 && c <= 57343) c = 65533;
			if (c < 2048) {
				out[n++] = 192 | c >> 6;
				out[n++] = 128 | c & 63;
			} else {
				out[n++] = 224 | c >> 12;
				out[n++] = 128 | c >> 6 & 63;
				out[n++] = 128 | c & 63;
			}
		}
		return out.slice(0, n);
	}
	function byteLength(text) {
		let n = text.length;
		for (let i = 0; i < text.length; i++) {
			const code = text.charCodeAt(i);
			if (code < 128) continue;
			if (code < 2048) n += 1;
			else if (code >= 55296 && code <= 56319 && i + 1 < text.length) {
				n += 2;
				i++;
			} else if (code < 56448 || code > 56575) n += 2;
		}
		return n;
	}
	function decode(bytes) {
		try {
			return strict.decode(bytes);
		} catch {
			return escaped(bytes);
		}
	}
	function escaped(bytes) {
		const units = new Uint16Array(bytes.length);
		const length = bytes.length;
		const cont = (i) => i < length && (bytes[i] & 192) === 128;
		let n = 0;
		let i = 0;
		while (i < length) {
			const b = bytes[i];
			if (b < 128) {
				units[n++] = b;
				i++;
				continue;
			}
			const b1 = bytes[i + 1] ?? 0;
			if (b >= 194 && b <= 223 && cont(i + 1)) {
				units[n++] = (b & 31) << 6 | b1 & 63;
				i += 2;
				continue;
			}
			if (b >= 224 && b <= 239 && b1 >= (b === 224 ? 160 : 128) && b1 <= (b === 237 ? 159 : 191) && cont(i + 2)) {
				units[n++] = (b & 15) << 12 | (b1 & 63) << 6 | bytes[i + 2] & 63;
				i += 3;
				continue;
			}
			if (b >= 240 && b <= 244 && b1 >= (b === 240 ? 144 : 128) && b1 <= (b === 244 ? 143 : 191) && cont(i + 2) && cont(i + 3)) {
				const c = ((b & 7) << 18 | (b1 & 63) << 12 | (bytes[i + 2] & 63) << 6 | bytes[i + 3] & 63) - 65536;
				units[n++] = 55296 + (c >> 10);
				units[n++] = 56320 + (c & 1023);
				i += 4;
				continue;
			}
			units[n++] = 56320 + b;
			i++;
		}
		let out = "";
		for (let start = 0; start < n; start += 32768) out += String.fromCharCode(...units.subarray(start, Math.min(n, start + 32768)));
		return out;
	}
	function rejoin(text) {
		return wellFormed(text) ? text : decode(encode(text));
	}
	// src/bash/internal/Syntax.ts
	var SyntaxError = class extends Error {};
	const sources = /* @__PURE__ */ new WeakMap();
	const texts = /* @__PURE__ */ new WeakMap();
	const heredocs = /* @__PURE__ */ new WeakMap();
	const forced = /* @__PURE__ */ new WeakSet();
	const newlines = /* @__PURE__ */ new WeakSet();
	const META = " 	\n;&|()<>";
	const RESERVED_STOP = /* @__PURE__ */ new Set([
		"then",
		"elif",
		"else",
		"fi",
		"do",
		"done",
		"esac",
		"}"
	]);
	const NAME$1 = /^[A-Za-z_][A-Za-z0-9_]*/;
	const SPECIAL = "@*#?$!-0";
	function parse(source) {
		const parser = new Parser(source);
		const script = parser.list(/* @__PURE__ */ new Set());
		parser.blanks();
		if (!parser.done()) throw new SyntaxError("syntax error near unexpected token `" + parser.peekToken() + "'");
		return script;
	}
	var Parser = class Parser {
		src;
		pos = 0;
		pending = [];
		edits = [];
		#linePos = 0;
		#line = 1;
		constructor(src) {
			this.src = src;
		}
		line() {
			if (this.pos < this.#linePos) {
				this.#linePos = 0;
				this.#line = 1;
			}
			for (let i = this.#linePos; i < this.pos; i++) if (this.src[i] === "\n") this.#line++;
			this.#linePos = this.pos;
			return this.#line;
		}
		done() {
			return this.pos >= this.src.length;
		}
		peekToken() {
			return this.src.slice(this.pos).match(/^(;;|&&|\|\||[;&|()<>\n]|[^\s;&|()<>]+)/)?.[0].replace("\n", "newline") ?? "EOF";
		}
		fail() {
			throw new SyntaxError(this.done() ? "syntax error: unexpected end of file" : "syntax error near unexpected token `" + this.peekToken() + "'");
		}
		blanks() {
			for (;;) {
				const c = this.src[this.pos];
				if (c === " " || c === "	" || c === "\r") this.pos++;
				else if (c === "\\" && this.src[this.pos + 1] === "\n") this.pos += 2;
				else if (c === "#") while (!this.done() && this.src[this.pos] !== "\n") this.pos++;
				else break;
			}
		}
		newline() {
			this.pos++;
			for (const heredoc of this.pending.splice(0)) this.heredoc(heredoc);
		}
		separators() {
			for (;;) {
				this.blanks();
				if (this.src[this.pos] === "\n") this.newline();
				else break;
			}
		}
		heredoc(pending) {
			const lines = [];
			for (;;) {
				if (this.done()) break;
				let end = this.src.indexOf("\n", this.pos);
				if (end < 0) end = this.src.length;
				let line = this.src.slice(this.pos, end);
				this.pos = Math.min(end + 1, this.src.length);
				if (pending.strip) line = line.replace(/^\t+/, "");
				if (line === pending.delimiter) break;
				lines.push(line + "\n");
			}
			const body = lines.join("");
			heredocs.set(pending.redirect, {
				body,
				delimiter: pending.delimiter,
				quoted: !pending.expand,
				strip: pending.strip
			});
			pending.redirect.body = pending.expand ? new Parser(body).text() : [{
				type: "text",
				value: body,
				quoted: true
			}];
		}
		starts(text) {
			return this.src.startsWith(text, this.pos);
		}
		reserved() {
			return this.src.slice(this.pos).match(/^(\[\[|\]\]|[{}!]|[a-z]+)(?=[\s;&|()<>]|$)/)?.[1];
		}
		eat(word) {
			this.separators();
			if (this.reserved() !== word) this.fail();
			this.pos += word.length;
		}
		list(stop) {
			const script = [];
			for (;;) {
				this.separators();
				if (this.done() || this.starts(")") || this.starts(";;") || this.starts(";&")) break;
				const word = this.reserved();
				if (word && (stop.has(word) || RESERVED_STOP.has(word))) break;
				const start = this.pos;
				const item = this.andOr();
				script.push(item);
				this.blanks();
				if (this.starts(";;") || this.starts(";&")) break;
				const c = this.src[this.pos];
				if (c === "&" && !this.starts("&&")) {
					item.background = true;
					item.source = this.src.slice(start, this.pos).trim();
				}
				if (c === ";" || c === "&" && !this.starts("&&")) this.pos++;
				else if (c === "\n") {
					newlines.add(item);
					this.newline();
				} else break;
			}
			return script;
		}
		andOr() {
			const first = this.pipeline();
			const rest = [];
			for (;;) {
				this.blanks();
				const op = this.starts("&&") ? "&&" : this.starts("||") ? "||" : void 0;
				if (!op) break;
				this.pos += 2;
				this.separators();
				rest.push({
					op,
					pipeline: this.pipeline()
				});
			}
			return {
				first,
				rest
			};
		}
		pipeline() {
			this.blanks();
			let negate = false;
			let timed = false;
			for (;;) {
				if (this.reserved() === "!") {
					this.pos++;
					negate = !negate;
				} else if (this.reserved() === "time" && /^time(?:\s+-p)?[ \t]+[^\s;&|)#]/.test(this.src.slice(this.pos))) {
					this.pos += 4;
					this.blanks();
					if (/^-p(?=\s)/.test(this.src.slice(this.pos))) this.pos += 2;
					timed = true;
				} else break;
				this.blanks();
			}
			const commands = [this.command()];
			for (;;) {
				this.blanks();
				if (!this.starts("|") || this.starts("||")) break;
				this.pos++;
				if (this.starts("&")) {
					this.pos++;
					commands[commands.length - 1].redirects.push({
						fd: 2,
						op: ">&",
						target: [{
							type: "text",
							value: "1",
							quoted: false
						}]
					});
				}
				this.separators();
				commands.push(this.command());
			}
			return timed ? {
				negate,
				timed,
				commands
			} : {
				negate,
				commands
			};
		}
		command() {
			this.blanks();
			const word = this.reserved();
			let command;
			if (word === "if") command = this.ifCommand();
			else if (word === "for") command = this.forCommand();
			else if (word === "coproc") {
				this.pos += 6;
				this.blanks();
				const named = this.src.slice(this.pos).match(/^([A-Za-z_][A-Za-z0-9_]*)[ \t]+(?=[{(])/);
				if (named) this.pos += named[0].length;
				return {
					type: "coproc",
					name: named?.[1] ?? "COPROC",
					body: this.command(),
					redirects: []
				};
			} else if (word === "select") {
				this.pos += 3;
				command = {
					...this.forCommand(),
					select: true
				};
			} else if (word === "while" || word === "until") command = this.whileCommand(word);
			else if (word === "case") command = this.caseCommand();
			else if (word === "{") {
				this.pos++;
				const body = this.list(/* @__PURE__ */ new Set());
				this.eat("}");
				command = {
					type: "group",
					body,
					subshell: false,
					redirects: []
				};
			} else if (this.starts("((")) {
				this.pos += 2;
				const text = this.until("))");
				command = {
					type: "arith",
					expr: new Parser(text).text(),
					redirects: []
				};
				texts.set(command, text);
			} else if (this.starts("(")) {
				this.pos++;
				const body = this.list(/* @__PURE__ */ new Set());
				this.separators();
				if (!this.starts(")")) this.fail();
				this.pos++;
				command = {
					type: "group",
					body,
					subshell: true,
					redirects: []
				};
			} else if (word === "[[") command = this.testCommand();
			else if (word === "function") {
				this.pos += 8;
				this.blanks();
				const name = this.src.slice(this.pos).match(/^[^\s;&|()<>]+/)?.[0];
				if (!name) this.fail();
				this.pos += name.length;
				this.blanks();
				if (this.starts("()")) this.pos += 2;
				this.separators();
				return {
					type: "function",
					name,
					body: this.command(),
					redirects: []
				};
			} else {
				const fn = this.src.slice(this.pos).match(/^([A-Za-z_][\w.:-]*)[ \t]*\([ \t]*\)/);
				if (fn) {
					this.pos += fn[0].length;
					this.separators();
					return {
						type: "function",
						name: fn[1],
						body: this.command(),
						redirects: []
					};
				}
				return this.simple();
			}
			for (;;) {
				this.blanks();
				if (!this.redirect(command.redirects)) break;
			}
			return command;
		}
		until(end) {
			let depth = 0;
			const start = this.pos;
			while (!this.done()) {
				if (depth === 0 && this.starts(end)) {
					const text = this.src.slice(start, this.pos);
					this.pos += end.length;
					return text;
				}
				const c = this.src[this.pos];
				if (c === "(") depth++;
				else if (c === ")") depth--;
				this.pos++;
			}
			this.fail();
		}
		ifCommand() {
			this.pos += 2;
			const clauses = [];
			let otherwise;
			for (;;) {
				const cond = this.list(/* @__PURE__ */ new Set());
				this.eat("then");
				const body = this.list(/* @__PURE__ */ new Set());
				clauses.push({
					cond,
					body
				});
				this.separators();
				const next = this.reserved();
				if (next === "elif") {
					this.pos += 4;
					continue;
				}
				if (next === "else") {
					this.pos += 4;
					otherwise = this.list(/* @__PURE__ */ new Set());
				}
				this.eat("fi");
				return {
					type: "if",
					clauses,
					otherwise,
					redirects: []
				};
			}
		}
		doBody() {
			this.separators();
			if (this.starts(";")) this.pos++;
			this.eat("do");
			const body = this.list(/* @__PURE__ */ new Set());
			this.eat("done");
			return body;
		}
		forCommand() {
			this.pos += 3;
			this.blanks();
			if (this.starts("((")) {
				this.pos += 2;
				const parts = splitTop(this.until("))"));
				if (parts.length !== 3) this.fail();
				const [init, cond, step] = parts.map((part) => new Parser(part).text());
				this.blanks();
				if (this.starts(";")) this.pos++;
				const command = {
					type: "cfor",
					init,
					cond,
					step,
					body: this.doBody(),
					redirects: []
				};
				texts.set(command, parts);
				return command;
			}
			const name = this.src.slice(this.pos).match(NAME$1)?.[0];
			if (!name) this.fail();
			this.pos += name.length;
			this.separators();
			let items;
			if (this.reserved() === "in") {
				this.pos += 2;
				items = [];
				for (;;) {
					this.blanks();
					const c = this.src[this.pos];
					if (this.done() || c === ";" || c === "\n") break;
					items.push(this.word());
				}
			}
			return {
				type: "for",
				name,
				items,
				body: this.doBody(),
				redirects: []
			};
		}
		whileCommand(word) {
			this.pos += word.length;
			const cond = this.list(/* @__PURE__ */ new Set(["do"]));
			return {
				type: "while",
				until: word === "until",
				cond,
				body: this.doBody(),
				redirects: []
			};
		}
		caseCommand() {
			this.pos += 4;
			this.blanks();
			const word = this.word();
			this.eat("in");
			const items = [];
			for (;;) {
				this.separators();
				if (this.reserved() === "esac") {
					this.pos += 4;
					break;
				}
				if (this.starts("(")) this.pos++;
				const patterns = [];
				for (;;) {
					this.blanks();
					patterns.push(this.word());
					this.blanks();
					if (this.starts("|")) {
						this.pos++;
						continue;
					}
					if (!this.starts(")")) this.fail();
					this.pos++;
					break;
				}
				const body = this.list(/* @__PURE__ */ new Set(["esac"]));
				this.separators();
				let next = "break";
				if (this.starts(";;&")) {
					this.pos += 3;
					next = "test";
				} else if (this.starts(";;")) this.pos += 2;
				else if (this.starts(";&")) {
					this.pos += 2;
					next = "fall";
				}
				items.push({
					patterns,
					body,
					next
				});
			}
			return {
				type: "case",
				word,
				items,
				redirects: []
			};
		}
		testCommand() {
			this.pos += 2;
			const tokens = [];
			for (;;) {
				this.blanks();
				if (this.done()) this.fail();
				if (this.starts("\n")) {
					this.newline();
					continue;
				}
				if (this.reserved() === "]]") {
					this.pos += 2;
					break;
				}
				const op = [
					"&&",
					"||",
					"(",
					")",
					"<",
					">"
				].find((op) => this.starts(op));
				if (op) {
					this.pos += op.length;
					tokens.push({ op });
					continue;
				}
				const last = tokens[tokens.length - 1];
				const regex = last !== void 0 && "word" in last && last.word.length === 1 && last.word[0].type === "text" && !last.word[0].quoted && last.word[0].value === "=~";
				tokens.push({ word: this.word(regex) });
			}
			return {
				type: "test",
				tokens,
				redirects: []
			};
		}
		simple() {
			const command = {
				type: "simple",
				assigns: [],
				words: [],
				redirects: [],
				line: this.line()
			};
			for (;;) {
				this.blanks();
				if (this.done()) break;
				const c = this.src[this.pos];
				if ((c === "<" || c === ">") && this.src[this.pos + 1] === "(") {
					command.words.push(this.word());
					continue;
				}
				if (this.redirect(command.redirects)) continue;
				if (c === "\n" || c === ";" || c === "|" || c === "&" || c === ")" || c === "(") break;
				const declaring = command.words.length > 0 && isDeclaration(command.words[0]);
				if (!command.words.length || declaring) {
					const assign = this.src.slice(this.pos).match(/^([A-Za-z_][A-Za-z0-9_]*)(\[[^\]]*\])?(\+?)=/);
					if (assign) {
						this.pos += assign[0].length;
						const entry = {
							name: assign[1],
							append: assign[3] === "+"
						};
						if (assign[2]) {
							entry.index = new Parser(assign[2].slice(1, -1)).text();
							texts.set(entry, assign[2]);
						}
						if (this.starts("(")) {
							this.pos++;
							entry.items = [];
							for (;;) {
								this.separators();
								if (this.starts(")")) {
									this.pos++;
									break;
								}
								if (this.done()) this.fail();
								const key = this.src.slice(this.pos, this.pos + 4096).match(/^\[([^\]\n]*)\]=/);
								if (key) {
									entry.keys ??= [];
									const keyWord = new Parser(key[1]).text();
									sources.set(keyWord, {
										edits: [],
										start: 0,
										text: key[1]
									});
									entry.keys[entry.items.length] = keyWord;
									this.pos += key[0].length;
									if (this.done() || " 	\n)".includes(this.src[this.pos])) {
										entry.items.push([{
											type: "text",
											value: "",
											quoted: true
										}]);
										continue;
									}
								}
								entry.items.push(this.word());
							}
						} else entry.value = this.word();
						if (declaring) command.words.push(entry);
						else command.assigns.push(entry);
						continue;
					}
				}
				command.words.push(this.word());
			}
			if (!command.words.length && !command.assigns.length && !command.redirects.length) this.fail();
			return command;
		}
		redirect(redirects) {
			const match = this.src.slice(this.pos).match(/^(\d*|\{[A-Za-z_][A-Za-z0-9_]*(?:\[\d+\])?\})(<<<|<<-|<<|<>|<&|>>|>&|>\||&>>|&>|<|>)/);
			if (!match) return false;
			if (match[2].startsWith("&") && match[1]) return false;
			this.pos += match[0].length;
			this.blanks();
			const named = match[1].startsWith("{") ? match[1].slice(1, -1) : void 0;
			const redirect = {
				fd: match[1] && !named ? Number(match[1]) : null,
				op: match[2] === ">|" ? ">" : match[2],
				target: [],
				...named !== void 0 ? { name: named } : {}
			};
			if (match[2] === ">|") forced.add(redirect);
			if (match[2] === "<<" || match[2] === "<<-") {
				const raw = this.src.slice(this.pos).match(/^[^\s;&|()<>]+/)?.[0];
				if (!raw) this.fail();
				this.pos += raw.length;
				const expand = !/['"\\]/.test(raw);
				this.pending.push({
					redirect,
					delimiter: raw.replace(/['"\\]/g, ""),
					strip: match[2] === "<<-",
					expand
				});
			} else {
				if (!(this.starts("<(") || this.starts(">(")) && (this.done() || META.includes(this.src[this.pos]))) this.fail();
				redirect.target = this.word();
			}
			redirects.push(redirect);
			return true;
		}
		word(regex = false) {
			const start = this.pos;
			const outer = this.edits;
			this.edits = [];
			const parts = this.wordParts(regex);
			sources.set(parts, {
				edits: this.edits,
				start,
				text: this.src.slice(start, this.pos)
			});
			this.edits = outer;
			return parts;
		}
		wordParts(regex) {
			const meta = regex ? " 	\n" : META;
			const parts = [];
			if ((this.src[this.pos] === "<" || this.src[this.pos] === ">") && this.src[this.pos + 1] === "(") {
				const output = this.src[this.pos] === ">";
				this.pos += 2;
				const outer = this.pending;
				this.pending = [];
				const body = this.list(/* @__PURE__ */ new Set());
				this.separators();
				this.pending = outer;
				if (!this.starts(")")) this.fail();
				this.pos++;
				parts.push({
					type: "process",
					body,
					output
				});
			}
			if (this.src[this.pos] === "~") {
				const user = this.src.slice(this.pos + 1).match(/^[A-Za-z0-9_-]*(?=[\/\s;&|()<>]|$)/);
				if (user) {
					parts.push({
						type: "tilde",
						user: user[0]
					});
					this.pos += 1 + user[0].length;
				}
			}
			while (!this.done()) {
				const c = this.src[this.pos];
				if (meta.includes(c)) break;
				if (c === "\\") {
					if (this.src[this.pos + 1] === "\n") this.pos += 2;
					else {
						push(parts, this.src[this.pos + 1] ?? "\\", true);
						this.pos += 2;
					}
				} else if (c === "'") {
					const end = this.src.indexOf("'", this.pos + 1);
					if (end < 0) throw new SyntaxError("unexpected EOF while looking for matching `''");
					push(parts, this.src.slice(this.pos + 1, end), true);
					this.pos = end + 1;
				} else if (c === "\"") {
					this.pos++;
					push(parts, "", true);
					this.double(parts, "\"");
					if (this.src[this.pos] !== "\"") throw new SyntaxError("unexpected EOF while looking for matching `\"'");
					this.pos++;
				} else if (c === "$" && this.src[this.pos + 1] === "'") {
					const start = this.pos;
					this.pos += 2;
					let value = "";
					while (!this.done() && this.src[this.pos] !== "'") if (this.src[this.pos] === "\\") {
						const [text, length] = ansiEscape(this.src, this.pos + 1);
						value += text;
						this.pos += 1 + length;
					} else value += this.src[this.pos++];
					if (this.done()) this.fail();
					this.pos++;
					this.edits.push({
						end: this.pos,
						start,
						value
					});
					push(parts, value, true);
				} else if (c === "$" || c === "`") parts.push(this.dollar(false));
				else {
					push(parts, c, false);
					this.pos++;
				}
			}
			return parts;
		}
		double(parts, end) {
			while (!this.done() && this.src[this.pos] !== end) {
				const c = this.src[this.pos];
				if (c === "\\") {
					const next = this.src[this.pos + 1];
					if (next === "\n") this.pos += 2;
					else if (next !== void 0 && ("$`\\" + (end ?? "")).includes(next)) {
						push(parts, next, true);
						this.pos += 2;
					} else {
						push(parts, "\\", true);
						this.pos++;
					}
				} else if (c === "$" || c === "`") parts.push(this.dollar(true));
				else {
					push(parts, c, true);
					this.pos++;
				}
			}
		}
		text() {
			const parts = [];
			this.double(parts, void 0);
			return parts;
		}
		dollar(quoted) {
			if (this.src[this.pos] === "`") {
				this.pos++;
				let inner = "";
				while (!this.done() && this.src[this.pos] !== "`") if (this.src[this.pos] === "\\" && "$`\\".includes(this.src[this.pos + 1])) {
					inner += this.src[this.pos + 1];
					this.pos += 2;
				} else inner += this.src[this.pos++];
				if (this.done()) this.fail();
				this.pos++;
				return {
					type: "command",
					body: parse(inner),
					quoted
				};
			}
			this.pos++;
			if (this.starts("((")) {
				const save = this.pos;
				this.pos += 2;
				try {
					return {
						type: "arith",
						expr: new Parser(this.until("))")).text(),
						quoted
					};
				} catch {
					this.pos = save;
				}
			}
			if (this.starts("(")) {
				const start = this.pos - 1;
				this.pos++;
				const outer = this.pending;
				this.pending = [];
				const body = this.list(/* @__PURE__ */ new Set());
				this.separators();
				this.pending = outer;
				if (!this.starts(")")) this.fail();
				this.pos++;
				this.edits.push({
					body,
					end: this.pos,
					start
				});
				return {
					type: "command",
					body,
					quoted
				};
			}
			if (this.starts("{")) {
				const start = this.pos++;
				try {
					return this.braced(quoted);
				} catch (error) {
					if (!(error instanceof SyntaxError)) throw error;
					const end = this.closing(start);
					if (end < 0) throw error;
					this.pos = end + 1;
					return {
						type: "param",
						name: this.src.slice(start - 1, end + 1),
						op: "bad",
						quoted
					};
				}
			}
			if (this.starts("[")) {
				this.pos++;
				return {
					type: "arith",
					expr: new Parser(this.until("]")).text(),
					quoted
				};
			}
			const name = this.src.slice(this.pos).match(NAME$1)?.[0];
			if (name) {
				this.pos += name.length;
				return {
					type: "param",
					name,
					op: "",
					quoted
				};
			}
			const c = this.src[this.pos];
			if (c !== void 0 && (/\d/.test(c) || SPECIAL.includes(c))) {
				this.pos++;
				return {
					type: "param",
					name: c,
					op: "",
					quoted
				};
			}
			return {
				type: "text",
				value: "$",
				quoted
			};
		}
		braced(quoted) {
			let op = "";
			if (this.starts("#") && !this.starts("#}")) {
				op = "length";
				this.pos++;
			} else if (this.starts("!") && !this.starts("!}")) {
				op = "indirect";
				this.pos++;
			}
			const name = this.src.slice(this.pos).match(/^([A-Za-z_][A-Za-z0-9_]*|\d+|[@*#?$!-])/)?.[0];
			if (!name) this.fail();
			this.pos += name.length;
			const part = {
				type: "param",
				name,
				op,
				quoted
			};
			if (this.starts("[")) {
				this.pos++;
				part.index = new Parser(this.until("]")).text();
			}
			if (this.starts("}")) {
				this.pos++;
				return part;
			}
			if (op === "indirect" && (this.starts("*}") || this.starts("@}"))) {
				this.pos += 2;
				part.op = "names";
				return part;
			}
			if (op === "length") this.fail();
			if (op === "indirect") {
				part.indirect = true;
				part.op = "";
			}
			if (this.starts("@") && /^@[QEPAaULuK]}/.test(this.src.slice(this.pos, this.pos + 3))) {
				part.op = "@" + this.src[this.pos + 1];
				this.pos += 3;
				return part;
			}
			const operator = [
				"//",
				"/#",
				"/%",
				"/",
				":-",
				":=",
				":+",
				":?",
				"-",
				"=",
				"+",
				"?",
				"##",
				"#",
				"%%",
				"%",
				"^^",
				"^",
				",,",
				","
			].find((op) => this.starts(op));
			if (operator) {
				this.pos += operator.length;
				part.op = operator;
				if (operator.startsWith("/")) {
					part.arg = this.argument("/}");
					if (this.starts("/")) {
						this.pos++;
						part.arg2 = this.argument("}");
					}
				} else part.arg = this.argument("}");
			} else if (this.starts(":")) {
				this.pos++;
				part.op = ":";
				part.arg = this.argument(":}");
				if (this.starts(":")) {
					this.pos++;
					part.arg2 = this.argument("}");
				}
			} else this.fail();
			if (!this.starts("}")) this.fail();
			this.pos++;
			return part;
		}
		closing(start) {
			let depth = 0;
			for (let i = start; i < this.src.length; i++) {
				const c = this.src[i];
				if (c === "\\") i++;
				else if (c === "{") depth++;
				else if (c === "}" && --depth === 0) return i;
				else if (c === "\n") return -1;
			}
			return -1;
		}
		argument(stops) {
			const parts = [];
			while (!this.done() && !stops.includes(this.src[this.pos])) {
				const c = this.src[this.pos];
				if (c === "\\") {
					push(parts, this.src[this.pos + 1] ?? "\\", true);
					this.pos += 2;
				} else if (c === "'") {
					const end = this.src.indexOf("'", this.pos + 1);
					if (end < 0) this.fail();
					push(parts, this.src.slice(this.pos + 1, end), true);
					this.pos = end + 1;
				} else if (c === "\"") {
					this.pos++;
					this.double(parts, "\"");
					this.pos++;
				} else if (c === "$" && this.src[this.pos + 1] === "'") {
					this.pos += 2;
					let value = "";
					while (!this.done() && this.src[this.pos] !== "'") if (this.src[this.pos] === "\\") {
						const [text, length] = ansiEscape(this.src, this.pos + 1);
						value += text;
						this.pos += 1 + length;
					} else value += this.src[this.pos++];
					this.pos++;
					push(parts, value, true);
				} else if (c === "$" || c === "`") parts.push(this.dollar(true));
				else {
					push(parts, c, false);
					this.pos++;
				}
			}
			return parts;
		}
	};
	const DECLARATIONS = /* @__PURE__ */ new Set([
		"local",
		"declare",
		"typeset",
		"export",
		"readonly"
	]);
	function isDeclaration(word) {
		return Array.isArray(word) && word.length === 1 && word[0].type === "text" && !word[0].quoted && DECLARATIONS.has(word[0].value);
	}
	function push(parts, value, quoted) {
		const last = parts[parts.length - 1];
		if (last?.type === "text" && last.quoted === quoted) last.value += value;
		else parts.push({
			type: "text",
			value,
			quoted
		});
	}
	function splitTop(text) {
		const parts = [];
		let depth = 0;
		let start = 0;
		for (let i = 0; i < text.length; i++) if (text[i] === "(") depth++;
		else if (text[i] === ")") depth--;
		else if (text[i] === ";" && depth === 0) {
			parts.push(text.slice(start, i));
			start = i + 1;
		}
		parts.push(text.slice(start));
		return parts;
	}
	function ansiEscape(src, pos) {
		const c = src[pos];
		const simple = {
			n: "\n",
			t: "	",
			r: "\r",
			a: "\x07",
			b: "\b",
			e: "\x1B",
			E: "\x1B",
			f: "\f",
			v: "\v",
			"\\": "\\",
			"'": "'",
			"\"": "\"",
			"?": "?",
			"0": "\0"
		};
		if (c === "x") {
			const hex = src.slice(pos + 1).match(/^[0-9a-fA-F]{1,2}/)?.[0];
			if (hex) return [byte(parseInt(hex, 16)), 1 + hex.length];
		}
		if (c === "u" || c === "U") {
			const hex = src.slice(pos + 1).match(c === "u" ? /^[0-9a-fA-F]{1,4}/ : /^[0-9a-fA-F]{1,8}/)?.[0];
			if (hex) return [String.fromCodePoint(parseInt(hex, 16)), 1 + hex.length];
		}
		if (c !== void 0 && /[0-7]/.test(c)) {
			const oct = src.slice(pos).match(/^[0-7]{1,3}/)[0];
			return [byte(parseInt(oct, 8)), oct.length];
		}
		if (c !== void 0 && c in simple) return [simple[c], 1];
		return ["\\" + (c ?? ""), c === void 0 ? 0 : 1];
	}
	// src/bash/internal/Print.ts
	const RESERVED = /* @__PURE__ */ new Set([
		"!",
		"[[",
		"]]",
		"case",
		"coproc",
		"do",
		"done",
		"elif",
		"else",
		"esac",
		"fi",
		"for",
		"function",
		"if",
		"in",
		"select",
		"then",
		"time",
		"until",
		"while",
		"{",
		"}"
	]);
	function functionText(name, body) {
		const printer = new Printer(false);
		printer.out = (RESERVED.has(name) ? "function " : "") + name + " () \n";
		printer.indentation = 4;
		printer.inside++;
		printer.out += "{ \n";
		const group = body.type === "group" && !body.subshell;
		if (group) printer.list(body.body);
		else printer.command(body);
		printer.flush("");
		printer.indentation = 0;
		printer.inside--;
		if (group && body.redirects.length) {
			printer.newline("} ");
			printer.redirects(body.redirects);
		} else printer.newline("}");
		return printer.out;
	}
	function wordText(word) {
		const source = sources.get(word);
		if (!source) return fallback(word);
		let text = "";
		let at = 0;
		for (const edit of source.edits) {
			const start = edit.start - source.start;
			if (start < at) continue;
			text += source.text.slice(at, start);
			text += edit.body ? "$(" + comsub(edit.body) + ")" : quote(edit.value ?? "");
			at = edit.end - source.start;
		}
		return (text + source.text.slice(at)).replaceAll("\\\n", "");
	}
	function comsub(body) {
		const printer = new Printer(true);
		printer.list(body);
		printer.flush("");
		return printer.out;
	}
	function quote(value) {
		return "'" + value.replaceAll("'", "'\\''") + "'";
	}
	function fallback(word) {
		return word.map((part) => {
			if (part.type === "text") return part.quoted ? part.value ? quote(part.value) : "''" : part.value.replace(/[\s'"\\$\x60;&|()<>*?[\]#~]/g, "\\$&");
			if (part.type === "param") return "${" + part.name + "}";
			if (part.type === "command") return "$(" + comsub(part.body) + ")";
			if (part.type === "arith") return "$((" + fallback(part.expr) + "))";
			if (part.type === "tilde") return "~" + part.user;
			return (part.output ? ">(" : "<(") + comsub(part.body) + ")";
		}).join("");
	}
	function assignText(assign) {
		const index = texts.get(assign);
		let text = assign.name + (typeof index === "string" ? index : assign.index ? "[" + wordText(assign.index) + "]" : "") + (assign.append ? "+=" : "=");
		if (assign.items) text += "(" + assign.items.map((item, i) => {
			const key = assign.keys?.[i];
			return (key ? "[" + wordText(key) + "]=" : "") + wordText(item);
		}).join(" ") + ")";
		else if (assign.value) text += wordText(assign.value);
		return text;
	}
	var Printer = class {
		out = "";
		indentation = 0;
		skip = 0;
		inside = 0;
		connection = 0;
		deferred = [];
		heredoc = false;
		comsub;
		constructor(comsub) {
			this.comsub = comsub;
		}
		indent() {
			this.out += " ".repeat(this.indentation);
		}
		lead() {
			if (this.skip) this.skip--;
			else this.indent();
		}
		newline(text) {
			this.out += "\n";
			this.indent();
			this.out += text;
		}
		semicolon() {
			const last = this.out[this.out.length - 1];
			if (last !== "&" && last !== "\n") this.out += ";";
		}
		flush(text) {
			const shown = text !== "" && (text[0] !== ";" || text.length > 1);
			if (shown) this.out += text;
			if (!this.deferred.length) return;
			this.bodies(this.deferred);
			if (shown) this.out += " ";
			this.deferred = [];
		}
		bodies(list) {
			this.out += "\n";
			for (const redirect of list) {
				const doc = heredocs.get(redirect);
				this.out += (doc?.body ?? "") + (doc?.delimiter ?? "") + "\n";
			}
			this.heredoc = true;
		}
		list(script) {
			const connection = script.length > 1 || script[script.length - 1]?.background === true;
			if (connection) this.connection++;
			script.forEach((item, index) => {
				this.andOr(item);
				if (index > 0) this.flush("");
				const more = index < script.length - 1;
				if (item.background) {
					this.flush(" &");
					if (more) {
						this.out += " ";
						this.skip++;
					}
				} else if (more) {
					const separator = this.comsub && newlines.has(item) ? "\n" : ";";
					if (!this.deferred.length) {
						if (!this.heredoc) this.out += separator;
						else this.heredoc = false;
					} else this.flush(this.inside ? "" : ";");
					if (this.inside) this.out += "\n";
					else {
						if (separator === ";") this.out += " ";
						this.skip++;
					}
				}
			});
			if (connection) {
				if (script.length === 1) this.flush("");
				this.connection--;
			}
		}
		andOr(item) {
			const connection = item.rest.length > 0;
			if (connection) this.connection++;
			this.pipeline(item.first);
			for (const next of item.rest) {
				this.flush(" " + next.op + " ");
				this.skip++;
				this.pipeline(next.pipeline);
				this.flush("");
			}
			if (connection) this.connection--;
		}
		pipeline(pipeline) {
			if (pipeline.negate) {
				this.lead();
				this.out += "! ";
				this.skip++;
			}
			const connection = pipeline.commands.length > 1;
			if (connection) this.connection++;
			pipeline.commands.forEach((command, index) => {
				if (index > 0) {
					this.flush(" |");
					this.out += " ";
					this.skip++;
				}
				this.command(command);
				if (index > 0) this.flush("");
			});
			if (connection) this.connection--;
		}
		loop(body) {
			this.newline("do\n");
			this.indentation += 4;
			this.list(body);
			this.flush("");
			this.semicolon();
			this.indentation -= 4;
			this.newline("done");
		}
		conditional(clauses, otherwise) {
			const [clause, ...rest] = clauses;
			if (!clause) return;
			this.out += "if ";
			this.skip++;
			this.list(clause.cond);
			this.semicolon();
			this.out += " then\n";
			this.indentation += 4;
			this.list(clause.body);
			this.flush("");
			this.indentation -= 4;
			if (rest.length || otherwise) {
				this.semicolon();
				this.newline("else\n");
				this.indentation += 4;
				if (rest.length) {
					this.indent();
					this.conditional(rest, otherwise);
				} else if (otherwise) {
					this.list(otherwise);
					this.flush("");
				}
				this.indentation -= 4;
			}
			this.semicolon();
			this.newline("fi");
		}
		command(command) {
			this.lead();
			switch (command.type) {
				case "simple": {
					const words = [...command.assigns.map(assignText), ...command.words.map((word) => Array.isArray(word) ? wordText(word) : assignText(word))];
					this.out += words.join(" ");
					if (command.redirects.length) {
						if (words.length) this.out += " ";
						this.redirects(command.redirects);
					}
					return;
				}
				case "for":
					this.out += (command.select ? "select " : "for ") + command.name + " in " + (command.items ? command.items.map(wordText).join(" ") : "\"$@\"") + ";";
					this.loop(command.body);
					break;
				case "cfor": {
					const parts = texts.get(command);
					const [init, cond, step] = (Array.isArray(parts) ? parts : [
						command.init,
						command.cond,
						command.step
					].map(wordText)).map((part) => part.trim() || "1");
					this.out += "for ((" + init + "; " + cond + "; " + step + "))";
					this.loop(command.body);
					break;
				}
				case "while":
					this.out += command.until ? "until " : "while ";
					this.skip++;
					this.list(command.cond);
					this.flush("");
					this.semicolon();
					this.out += " do\n";
					this.indentation += 4;
					this.list(command.body);
					this.flush("");
					this.indentation -= 4;
					this.semicolon();
					this.newline("done");
					break;
				case "if":
					this.conditional(command.clauses, command.otherwise);
					break;
				case "case":
					this.out += "case " + wordText(command.word) + " in ";
					this.indentation += 4;
					for (const item of command.items) {
						this.newline("");
						this.out += item.patterns.map(wordText).join(" | ") + ")\n";
						this.indentation += 4;
						this.list(item.body);
						this.indentation -= 4;
						this.flush("");
						this.newline(item.next === "fall" ? ";&" : item.next === "test" ? ";;&" : ";;");
					}
					this.indentation -= 4;
					this.newline("esac");
					break;
				case "coproc":
					this.out += "coproc " + (command.name === "COPROC" ? "" : command.name + " ");
					this.command(command.body);
					break;
				case "group":
					if (command.subshell) {
						this.out += "( ";
						this.skip++;
						this.list(command.body);
						this.flush("");
						this.out += " )";
						break;
					}
					this.out += "{ ";
					if (!this.inside) this.skip++;
					else {
						this.out += "\n";
						this.indentation += 4;
					}
					this.list(command.body);
					this.flush("");
					if (this.inside) {
						this.out += "\n";
						this.indentation -= 4;
						this.indent();
					} else {
						this.semicolon();
						this.out += " ";
					}
					this.out += "}";
					break;
				case "function": {
					this.out += "function " + command.name + " () \n";
					this.indent();
					this.out += "{ \n";
					this.inside++;
					this.indentation += 4;
					const body = command.body;
					const group = body.type === "group" && !body.subshell;
					if (group) this.list(body.body);
					else this.command(body);
					this.flush("");
					this.indentation -= 4;
					this.inside--;
					if (group && body.redirects.length) {
						this.newline("} ");
						this.redirects(body.redirects);
					} else this.newline("}");
					return;
				}
				case "arith": {
					const text = texts.get(command);
					this.out += "((" + (typeof text === "string" ? text : wordText(command.expr)) + "))";
					break;
				}
				case "test": this.out += "[[ " + command.tokens.map((token) => "op" in token ? token.op : wordText(token.word)).join(" ") + " ]]";
			}
			if (command.redirects.length) {
				this.out += " ";
				this.redirects(command.redirects);
			}
		}
		redirects(list) {
			this.heredoc = false;
			const docs = [];
			list.forEach((redirect, index) => {
				const doc = heredocs.get(redirect);
				if (doc) {
					this.out += (redirect.fd ? String(redirect.fd) : "") + "<<" + (doc.strip ? "-" : "") + (doc.quoted ? quote(doc.delimiter) : doc.delimiter);
					docs.push(redirect);
				} else this.out += redirectText(redirect);
				if (index < list.length - 1) this.out += " ";
			});
			if (!docs.length) return;
			if (this.connection) this.deferred.push(...docs);
			else this.bodies(docs);
		}
	};
	function redirectText(redirect) {
		if (redirect.name !== void 0) return "{" + redirect.name + "}" + redirectText({
			fd: null,
			op: redirect.op,
			target: redirect.target
		}).replace(/^\d+/, "");
		const target = wordText(redirect.target);
		const fd = redirect.fd;
		switch (redirect.op) {
			case "<": return (fd !== null && fd !== 0 ? fd : "") + "< " + target;
			case ">": return (fd !== null && fd !== 1 ? fd : "") + (forced.has(redirect) ? ">| " : "> ") + target;
			case ">>": return (fd !== null && fd !== 1 ? fd : "") + ">> " + target;
			case "<>": return (fd !== null && fd !== 0 ? fd : "") + "<> " + target;
			case "<<<": return (fd !== null && fd !== 0 ? fd : "") + "<<< " + target;
			case "&>":
			case "&>>": return redirect.op + " " + target;
			case "<&": return target === "-" ? (fd ?? 0) + ">&-" : (fd ?? 0) + "<&" + target;
			case ">&":
				if (/^(\d+|-)$/.test(target)) return (fd ?? 1) + ">&" + target;
				return (fd === null ? "" : fd) + ">&" + target;
		}
		return (fd ?? "") + redirect.op + " " + target;
	}
	// src/bash/internal/Arith.ts
	const OPERATORS = [
		"<<=",
		">>=",
		"**",
		"++",
		"--",
		"<<",
		">>",
		"<=",
		">=",
		"==",
		"!=",
		"&&",
		"||",
		"+=",
		"-=",
		"*=",
		"/=",
		"%=",
		"&=",
		"^=",
		"|=",
		"+",
		"-",
		"*",
		"/",
		"%",
		"<",
		">",
		"&",
		"^",
		"|",
		"!",
		"~",
		"?",
		":",
		"=",
		"(",
		")",
		"[",
		"]",
		","
	];
	const ASSIGN = /* @__PURE__ */ new Set([
		"=",
		"+=",
		"-=",
		"*=",
		"/=",
		"%=",
		"<<=",
		">>=",
		"&=",
		"^=",
		"|="
	]);
	const NUMBER = /0[xX][0-9a-zA-Z@_]*|\d+#[0-9a-zA-Z@_]*|\d[0-9a-zA-Z@_]*/y;
	const NAME = /[A-Za-z_][A-Za-z0-9_]*/y;
	const SAFE = BigInt(Number.MAX_SAFE_INTEGER);
	const CACHE = /* @__PURE__ */ new Map();
	var ArithError = class extends Error {};
	function normal(value) {
		const wrapped = BigInt.asIntN(64, value);
		return wrapped >= -SAFE && wrapped <= SAFE ? Number(wrapped) : wrapped;
	}
	function big(value) {
		return typeof value === "bigint" ? value : BigInt(value);
	}
	function digits(text, base, token) {
		if (base < 2 || base > 64) throw new ArithError("invalid arithmetic base (error token is \"" + token + "\")");
		let value = 0;
		for (const c of text) {
			const code = c.charCodeAt(0);
			const digit = code >= 48 && code <= 57 ? code - 48 : code >= 97 && code <= 122 ? code - 87 : code >= 65 && code <= 90 ? base <= 36 ? code - 55 : code - 29 : c === "@" ? 62 : c === "_" ? 63 : 64;
			if (digit >= base) throw new ArithError("value too great for base (error token is \"" + token + "\")");
			if (typeof value === "number") {
				const next = value * base + digit;
				value = next <= Number.MAX_SAFE_INTEGER ? next : BigInt(value) * BigInt(base) + BigInt(digit);
			} else value = BigInt.asUintN(64, value * BigInt(base) + BigInt(digit));
		}
		return typeof value === "bigint" ? normal(value) : value;
	}
	function literal(text) {
		if (/^0[xX]/.test(text)) {
			if (text.length === 2) throw new ArithError("invalid number (error token is \"" + text + "\")");
			return digits(text.slice(2), 16, text);
		}
		const hash = text.indexOf("#");
		if (hash > 0) {
			const base = Number(text.slice(0, hash));
			if (hash === text.length - 1) throw new ArithError("invalid number (error token is \"" + text + "\")");
			return digits(text.slice(hash + 1), base, text);
		}
		if (text.length > 1 && text[0] === "0") return digits(text.slice(1), 8, text);
		if (text.length <= 15 && /^\d+$/.test(text)) return Number(text);
		return digits(text, 10, text);
	}
	function tokenize(source) {
		const cached = CACHE.get(source);
		if (cached) return cached;
		const tokens = [];
		let i = 0;
		while (i < source.length) {
			const code = source.charCodeAt(i);
			if (code === 32 || code === 9 || code === 10 || code === 13 || code === 34 || code === 11 || code === 12) {
				i++;
				continue;
			}
			if (code >= 48 && code <= 57) {
				NUMBER.lastIndex = i;
				const text = NUMBER.exec(source)[0];
				tokens.push({
					kind: "num",
					value: literal(text)
				});
				i += text.length;
				continue;
			}
			if (code === 95 || code >= 65 && code <= 90 || code >= 97 && code <= 122) {
				NAME.lastIndex = i;
				const name = NAME.exec(source)[0];
				tokens.push({
					kind: "name",
					value: name
				});
				i += name.length;
				continue;
			}
			const op = OPERATORS.find((op) => source.startsWith(op, i));
			if (!op) throw new ArithError("syntax error: invalid arithmetic operator (error token is \"" + source.slice(i) + "\")");
			tokens.push({
				kind: "op",
				value: op
			});
			i += op.length;
		}
		if (CACHE.size > 512) CACHE.clear();
		CACHE.set(source, tokens);
		return tokens;
	}
	const BINARY = {
		"||": 1,
		"&&": 2,
		"|": 3,
		"^": 4,
		"&": 5,
		"==": 6,
		"!=": 6,
		"<": 7,
		">": 7,
		"<=": 7,
		">=": 7,
		"<<": 8,
		">>": 8,
		"+": 9,
		"-": 9,
		"*": 10,
		"/": 10,
		"%": 10,
		"**": 11
	};
	function power(base, exponent) {
		if (exponent < 0) throw new ArithError("exponent less than 0 (error token is \"" + String(exponent) + "\")");
		if (typeof base === "number" && typeof exponent === "number") {
			const result = base ** exponent;
			if (Number.isSafeInteger(result)) return result;
		}
		let result = 1n;
		let factor = BigInt.asUintN(64, big(base));
		let rest = big(exponent);
		while (rest > 0n) {
			if (rest & 1n) result = BigInt.asUintN(64, result * factor);
			factor = BigInt.asUintN(64, factor * factor);
			rest >>= 1n;
		}
		return normal(result);
	}
	function shift(count) {
		return typeof count === "number" && count >= 0 && count < 64 ? count : Number(BigInt.asUintN(6, big(count)));
	}
	function apply(op, a, b, run) {
		const small = typeof a === "number" && typeof b === "number";
		switch (op) {
			case "+":
				if (small) {
					const result = a + b;
					if (result <= Number.MAX_SAFE_INTEGER && result >= -Number.MAX_SAFE_INTEGER) return result;
				}
				return normal(big(a) + big(b));
			case "-":
				if (small) {
					const result = a - b;
					if (result <= Number.MAX_SAFE_INTEGER && result >= -Number.MAX_SAFE_INTEGER) return result;
				}
				return normal(big(a) - big(b));
			case "*":
				if (small) {
					const result = a * b;
					if (result <= Number.MAX_SAFE_INTEGER && result >= -Number.MAX_SAFE_INTEGER) return result + 0;
				}
				return normal(big(a) * big(b));
			case "/":
			case "%":
				if (b == 0) {
					if (!run) return 0;
					throw new ArithError("division by 0 (error token is \"" + String(b) + "\")");
				}
				if (small) {
					const rest = a % b;
					return op === "%" ? rest + 0 : (a - rest) / b + 0;
				}
				return normal(op === "/" ? big(a) / big(b) : big(a) % big(b));
			case "**": return power(a, b);
			case "<<": {
				const count = shift(b);
				if (typeof a === "number" && count < 32) {
					const result = a * 2 ** count;
					if (result <= Number.MAX_SAFE_INTEGER && result >= -Number.MAX_SAFE_INTEGER) return result;
				}
				return normal(big(a) << BigInt(count));
			}
			case ">>": {
				const count = shift(b);
				if (typeof a === "number") return Math.floor(a / 2 ** count);
				return normal(a >> BigInt(count));
			}
			case "<": return Number(a < b);
			case ">": return Number(a > b);
			case "<=": return Number(a <= b);
			case ">=": return Number(a >= b);
			case "==": return Number(a == b);
			case "!=": return Number(a != b);
			case "&":
			case "|":
			case "^":
				if (small && a === (a | 0) && b === (b | 0)) return op === "&" ? a & b : op === "|" ? a | b : a ^ b;
				return normal(op === "&" ? big(a) & big(b) : op === "|" ? big(a) | big(b) : big(a) ^ big(b));
		}
		throw new ArithError("unknown operator " + op);
	}
	function numeric(text) {
		const length = text.length;
		if (!length || length > 20) return void 0;
		let start = text.charCodeAt(0) === 45 ? 1 : 0;
		if (start === length || text.charCodeAt(start) === 48 && length > start + 1) return void 0;
		for (let i = start; i < length; i++) {
			const code = text.charCodeAt(i);
			if (code < 48 || code > 57) return void 0;
		}
		return length <= 15 ? Number(text) : normal(BigInt(text));
	}
	function evaluateArith(source, scope, depth = 0) {
		if (depth > 32) throw new ArithError("expression recursion level exceeded");
		const tokens = tokenize(source);
		let pos = 0;
		const peek = () => tokens[pos];
		const isOp = (value) => {
			const token = tokens[pos];
			return token !== void 0 && token.kind === "op" && token.value === value;
		};
		const expect = (value) => {
			if (!isOp(value)) throw new ArithError("syntax error in expression (error token is \"" + (peek() ? String(peek().value) : "") + "\")");
			pos++;
		};
		const variable = (name, index) => {
			const raw = scope.get(name, index);
			const fast = numeric(raw);
			if (fast !== void 0) return fast;
			const text = raw.trim();
			if (text === "") return 0;
			return numeric(text) ?? evaluateArith(text, scope, depth + 1);
		};
		const subscript = (run) => {
			if (!isOp("[")) return void 0;
			pos++;
			const index = comma(run);
			expect("]");
			return Number(index);
		};
		function comma(run) {
			let value = assign(run);
			while (isOp(",")) {
				pos++;
				value = assign(run);
			}
			return value;
		}
		function assign(run) {
			const token = peek();
			if (token?.kind === "name") {
				const save = pos;
				pos++;
				const index = subscript(run);
				const next = peek();
				if (next?.kind === "op" && ASSIGN.has(next.value)) {
					pos++;
					const right = assign(run);
					const value = next.value === "=" ? right : apply(next.value.slice(0, -1), variable(token.value, index), right, run);
					if (run) scope.set(token.value, value, index);
					return value;
				}
				pos = save;
			}
			return ternary(run);
		}
		function ternary(run) {
			const cond = binary(1, run);
			if (!isOp("?")) return cond;
			pos++;
			const yes = comma(run && cond != 0);
			expect(":");
			const no = assign(run && cond == 0);
			return cond != 0 ? yes : no;
		}
		function binary(min, run) {
			let left = unary(run);
			for (;;) {
				const token = peek();
				if (token?.kind !== "op") break;
				const prec = BINARY[token.value];
				if (prec === void 0 || prec < min) break;
				pos++;
				if (token.value === "&&") {
					const right = binary(prec + 1, run && left != 0);
					left = Number(left != 0 && right != 0);
				} else if (token.value === "||") {
					const right = binary(prec + 1, run && left == 0);
					left = Number(left != 0 || right != 0);
				} else {
					const right = binary(token.value === "**" ? prec : prec + 1, run);
					left = apply(token.value, left, right, run);
				}
			}
			return left;
		}
		function unary(run) {
			const token = peek();
			if (token?.kind === "op") {
				if (token.value === "++" || token.value === "--") {
					pos++;
					const name = peek();
					if (name?.kind !== "name") throw new ArithError("syntax error: operand expected");
					pos++;
					const index = subscript(run);
					const value = apply(token.value === "++" ? "+" : "-", variable(name.value, index), 1, run);
					if (run) scope.set(name.value, value, index);
					return value;
				}
				if (token.value === "+" || token.value === "-" || token.value === "!" || token.value === "~") {
					pos++;
					const value = unary(run);
					if (token.value === "-") return typeof value === "number" ? 0 - value : normal(-value);
					if (token.value === "!") return Number(value == 0);
					if (token.value === "~") return typeof value === "number" && value === (value | 0) ? ~value : normal(~big(value));
					return value;
				}
			}
			return postfix(run);
		}
		function postfix(run) {
			const token = peek();
			if (!token) throw new ArithError("syntax error: operand expected");
			pos++;
			if (token.kind === "num") return token.value;
			if (token.kind === "op") {
				if (token.value !== "(") throw new ArithError("syntax error: operand expected (error token is \"" + token.value + "\")");
				const value = comma(run);
				expect(")");
				return value;
			}
			const index = subscript(run);
			const value = variable(token.value, index);
			if (isOp("++") || isOp("--")) {
				const op = String(tokens[pos++].value);
				if (run) scope.set(token.value, apply(op === "++" ? "+" : "-", value, 1, run), index);
			}
			return value;
		}
		if (!tokens.length) return 0;
		const value = comma(true);
		if (pos < tokens.length) throw new ArithError("syntax error in expression (error token is \"" + String(tokens[pos].value) + "\")");
		return value;
	}
	// src/bash/internal/Text.ts
	const CLASSES = {
		alpha: "a-zA-Z",
		digit: "0-9",
		alnum: "a-zA-Z0-9",
		upper: "A-Z",
		lower: "a-z",
		space: " \\t\\n\\r\\f\\v",
		blank: " \\t",
		punct: "!-\\/:-@\\[-`{-~",
		xdigit: "0-9A-Fa-f",
		word: "\\w",
		cntrl: "\\x00-\\x1f\\x7f",
		print: "\\x20-\\x7e",
		graph: "\\x21-\\x7e"
	};
	function bracket$1(pattern, start, shell) {
		let i = start + 1;
		let out = "[";
		if (pattern[i] === "!" || pattern[i] === "^") {
			out += "^";
			i++;
		}
		let first = true;
		while (i < pattern.length) {
			const c = pattern[i];
			if (c === "]" && !first) return [out + "]", i + 1];
			first = false;
			if (c === "[" && pattern[i + 1] === ":") {
				const end = pattern.indexOf(":]", i + 2);
				if (end > 0) {
					out += CLASSES[pattern.slice(i + 2, end)] ?? "";
					i = end + 2;
					continue;
				}
			}
			if (c === "\\" && shell && i + 1 < pattern.length) {
				out += "\\" + pattern[i + 1];
				i += 2;
				continue;
			}
			out += c === "\\" || c === "]" || c === "[" || c === "^" ? "\\" + c : c;
			i++;
		}
	}
	function escapeRegExp(text) {
		return text.replace(/[.*+?^${}()|[\]\\\/]/g, "\\$&");
	}
	function globSource(pattern, path = false) {
		let out = "";
		for (let i = 0; i < pattern.length; i++) {
			const c = pattern[i];
			if (c === "\\" && i + 1 < pattern.length) out += escapeRegExp(pattern[++i]);
			else if (c === "*") out += path ? "[^/]*" : "[\\s\\S]*";
			else if (c === "?") out += path ? "[^/]" : "[\\s\\S]";
			else if (c === "[") {
				const result = bracket$1(pattern, i, true);
				if (result) {
					out += result[0];
					i = result[1] - 1;
				} else out += "\\[";
			} else out += escapeRegExp(c);
		}
		return out;
	}
	function globRegExp(pattern, flags = "") {
		return new RegExp("^" + globSource(pattern) + "$", flags);
	}
	function posixRegExp(pattern, extended, flags = "") {
		let out = "";
		for (let i = 0; i < pattern.length; i++) {
			const c = pattern[i];
			if (c === "\\" && i + 1 < pattern.length) {
				const n = pattern[++i];
				if (n === "<" || n === ">") out += "\\b";
				else if (!extended && "(){}+?|".includes(n)) out += n;
				else if (/[wWsSbBdD1-9]/.test(n)) out += "\\" + n;
				else if (n === "n") out += "\\n";
				else if (n === "t") out += "\\t";
				else if (n === "r") out += "\\r";
				else if (n === "f") out += "\\f";
				else if (n === "v") out += "\\v";
				else out += escapeRegExp(n);
			} else if (c === "[") {
				const result = bracket$1(pattern, i, false);
				if (result) {
					out += result[0];
					i = result[1] - 1;
				} else out += "\\[";
			} else if (!extended && "(){}+?|".includes(c)) out += "\\" + c;
			else if (c === "*" && (out === "" || out.endsWith("(") || out.endsWith("|") || out === "^")) out += "\\*";
			else if (extended && c === "{" && !/^\{\d+(,\d*)?\}/.test(pattern.slice(i))) out += "\\{";
			else if (extended && c === "}" && !/\{\d+(,\d*)?$/.test(out)) out += "\\}";
			else if (c === "/") out += "\\/";
			else out += c;
		}
		return new RegExp(out, flags);
	}
	function lines(text) {
		if (text === "") return [];
		const parts = text.split("\n");
		if (parts[parts.length - 1] === "") parts.pop();
		return parts;
	}
	function joinLines(parts) {
		return parts.length ? parts.join("\n") + "\n" : "";
	}
	const ESCAPE = /^\\(0[0-7]{0,3}|x[0-9a-fA-F]{1,2}|u[0-9a-fA-F]{1,4}|U[0-9a-fA-F]{1,8}|[\s\S])/;
	const FORMAT_ESCAPE = /^\\(0[0-7]{0,3}|[1-7][0-7]{0,2}|x[0-9a-fA-F]{1,2}|u[0-9a-fA-F]{1,4}|U[0-9a-fA-F]{1,8}|[\s\S])/;
	const OCTAL = /^\\([0-7]{1,3}|x[0-9a-fA-F]{1,2}|u[0-9a-fA-F]{1,4}|U[0-9a-fA-F]{1,8}|[\s\S])/;
	const SIMPLE = {
		n: "\n",
		t: "	",
		r: "\r",
		a: "\x07",
		b: "\b",
		e: "\x1B",
		f: "\f",
		v: "\v",
		"\\": "\\"
	};
	function escape$1(text, octal = false, format = false) {
		const match = text.match(octal ? OCTAL : format ? FORMAT_ESCAPE : ESCAPE);
		if (!match) return [
			"\\",
			1,
			false
		];
		const body = match[1];
		if (body === "c") return [
			"",
			2,
			true
		];
		if (format && /^[1-7]/.test(body)) return [
			byte(parseInt(body, 8)),
			match[0].length,
			false
		];
		if (octal ? /^[0-7]/.test(body) : body[0] === "0") return [
			byte(parseInt((octal ? body : body.slice(1)) || "0", 8)),
			match[0].length,
			false
		];
		if (body.length > 1 && body[0] === "x") return [
			byte(parseInt(body.slice(1), 16)),
			match[0].length,
			false
		];
		if (body.length > 1 && (body[0] === "u" || body[0] === "U")) return [
			String.fromCodePoint(parseInt(body.slice(1), 16)),
			match[0].length,
			false
		];
		return [
			body in SIMPLE ? SIMPLE[body] : "\\" + body,
			match[0].length,
			false
		];
	}
	function escapes(text, format = false) {
		let out = "";
		for (let i = 0; i < text.length; i++) {
			if (text[i] !== "\\" || i + 1 >= text.length) {
				out += text[i];
				continue;
			}
			const [value, length, stop] = escape$1(text.slice(i), false, format);
			if (stop) return [out, true];
			out += value;
			i += length - 1;
		}
		return [out, false];
	}
	// src/bash/internal/Shell.ts
	var LimitError = class extends Error {
		status;
		constructor(message, status = 126) {
			super(message);
			this.status = status;
		}
	};
	function megabytes(bytes) {
		return (bytes / 1048576).toFixed(bytes < 10485760 ? 1 : 0) + " MB";
	}
	function budget(limits, bytes, what) {
		if (bytes > limits.maxMemoryBytes) throw new LimitError(what + " needs about " + megabytes(bytes) + ", which exceeds this host's memory budget of " + megabytes(limits.maxMemoryBytes));
	}
	var CommandError = class extends Error {
		name = "Command.CommandError";
		status;
		constructor(message, status = 1) {
			super(message);
			this.status = status;
		}
	};
	var ExitSignal = class {
		status;
		constructor(status) {
			this.status = status;
		}
	};
	var ReturnSignal = class {
		status;
		constructor(status) {
			this.status = status;
		}
	};
	var LoopSignal = class {
		kind;
		levels;
		constructor(kind, levels) {
			this.kind = kind;
			this.levels = levels;
		}
	};
	var PipeError = class extends Error {
		name = "Command.PipeError";
		constructor() {
			super("Broken pipe");
		}
	};
	var KillSignal = class {
		status;
		constructor(status) {
			this.status = status;
		}
	};
	const WHOLE_INPUT = 16;
	var Input = class Input {
		#text;
		#pos = 0;
		#scan = 0;
		#pipe;
		#done = true;
		constructor(text = "") {
			this.#text = text;
		}
		static pipe(pipe) {
			const input = new Input();
			input.#pipe = pipe;
			input.#done = false;
			return input;
		}
		get ready() {
			return this.#done;
		}
		#refuse(size) {
			const pipe = this.#pipe;
			if (size > pipe.memory) throw new LimitError("input of more than " + megabytes(pipe.memory) + " exceeds this host's memory budget of " + megabytes(pipe.memory));
			throw new LimitError("input exceeded " + pipe.limit * WHOLE_INPUT + " characters");
		}
		#pending() {
			throw new Error("stdin is an open pipe; read it with await stdin.text(), chunk() or readLine()");
		}
		async #more() {
			if (this.#done) return false;
			const chunk = await this.#pipe.take();
			if (chunk === null) {
				this.#done = true;
				return false;
			}
			const rest = this.#text.length - this.#pos;
			if (rest + chunk.length > Math.min(this.#pipe.limit * WHOLE_INPUT, this.#pipe.memory)) this.#refuse(rest + chunk.length);
			this.#scan = Math.max(0, this.#scan - this.#pos);
			this.#text = rest ? this.#text.slice(this.#pos) + chunk : chunk;
			this.#pos = 0;
			return true;
		}
		async fill() {
			if (this.#done || !this.#pipe) return;
			const pipe = this.#pipe;
			const cap = Math.min(pipe.limit * WHOLE_INPUT, pipe.memory);
			const parts = [this.#pos ? this.#text.slice(this.#pos) : this.#text];
			let size = parts[0].length;
			for (let chunk = await pipe.take(); chunk !== null; chunk = await pipe.take()) {
				size += chunk.length;
				if (size > cap) this.#refuse(size);
				parts.push(chunk);
			}
			this.#done = true;
			this.#text = rejoin(parts.join(""));
			this.#pos = this.#scan = 0;
		}
		async text() {
			await this.fill();
			return this.read();
		}
		async chunk() {
			if (this.#pos >= this.#text.length && !await this.#more()) return null;
			const text = this.#pos ? this.#text.slice(this.#pos) : this.#text;
			this.#text = "";
			this.#pos = this.#scan = 0;
			return this.#pipe ? rejoin(text) : text;
		}
		async readLine(delimiter = "\n") {
			const mark = delimiter === "" ? "\0" : delimiter;
			for (;;) {
				const end = this.#text.indexOf(mark, Math.max(this.#pos, this.#scan));
				if (end >= 0) {
					const text = this.#text.slice(this.#pos, end);
					this.#pos = this.#scan = end + mark.length;
					return {
						text: this.#pipe ? rejoin(text) : text,
						complete: true
					};
				}
				this.#scan = Math.max(this.#pos, this.#text.length - mark.length + 1);
				if (!await this.#more()) break;
			}
			if (this.#pos >= this.#text.length) return null;
			const text = this.#text.slice(this.#pos);
			this.#text = "";
			this.#pos = this.#scan = 0;
			return {
				text: this.#pipe ? rejoin(text) : text,
				complete: false
			};
		}
		async readChars(count) {
			while (this.#text.length - this.#pos < count && await this.#more());
			return this.chars(count);
		}
		close() {
			this.#pipe?.close();
			if (!this.#done) {
				this.#done = true;
				this.#text = "";
				this.#pos = 0;
			}
		}
		read() {
			if (!this.#done) this.#pending();
			const rest = this.#text.slice(this.#pos);
			this.#pos = this.#text.length;
			return rest;
		}
		line(delimiter = "\n") {
			if (!this.#done) this.#pending();
			if (this.#pos >= this.#text.length) return null;
			const end = delimiter === "" ? this.#text.indexOf("\0", this.#pos) : this.#text.indexOf(delimiter, this.#pos);
			if (end < 0) return {
				text: this.read(),
				complete: false
			};
			const text = this.#text.slice(this.#pos, end);
			this.#pos = end + Math.max(1, delimiter.length);
			return {
				text,
				complete: true
			};
		}
		chars(count) {
			if (!this.#done && this.#text.length - this.#pos < count) this.#pending();
			const text = this.#text.slice(this.#pos, this.#pos + count);
			this.#pos += text.length;
			return text;
		}
	};
	const STREAMS = /* @__PURE__ */ new WeakSet();
	function streaming(handler) {
		STREAMS.add(handler);
		return handler;
	}
	function shellQuote(value) {
		if (/[\x00-\x1f\x7f]/.test(value)) return "$'" + value.replace(/[\\']/g, "\\$&").replace(/[\x00-\x1f\x7f]/g, (c) => ({
			"\n": "\\n",
			"	": "\\t",
			"\r": "\\r"
		})[c] ?? "\\" + c.charCodeAt(0).toString(8).padStart(3, "0")) + "'";
		return "'" + value.replace(/'/g, "'\\''") + "'";
	}
	function count$1(text, fallback) {
		if (text === void 0) return fallback;
		if (!/^-?\d+$/.test(text)) throw new CommandError(text + ": numeric argument required", 2);
		return Number(text);
	}
	function readFields(text, names, ifs) {
		const white = ifs.replace(/[^ \t\n]/g, "");
		const isWhite = (c) => white.includes(c);
		const isSep = (c) => ifs.includes(c);
		let pos = 0;
		while (pos < text.length && isWhite(text[pos])) pos++;
		const fields = [];
		while (fields.length < names - 1 && pos < text.length) {
			let end = pos;
			while (end < text.length && !isSep(text[end])) end++;
			fields.push(text.slice(pos, end));
			pos = end;
			while (pos < text.length && isWhite(text[pos])) pos++;
			if (pos < text.length && isSep(text[pos]) && !isWhite(text[pos])) {
				pos++;
				while (pos < text.length && isWhite(text[pos])) pos++;
			}
		}
		let rest = text.slice(pos);
		let end = rest.length;
		while (end > 0 && isWhite(rest[end - 1])) end--;
		rest = rest.slice(0, end);
		if (pos < text.length || fields.length < names) fields.push(rest);
		return fields;
	}
	const noop = async () => 0;
	async function physical(fs, path) {
		if (!fs.readlink) return path;
		const pending = path.split("/").filter(Boolean);
		const parts = [];
		let hops = 0;
		while (pending.length) {
			const part = pending.shift();
			if (part === ".") continue;
			if (part === "..") {
				parts.pop();
				continue;
			}
			const target = await fs.readlink("/" + [...parts, part].join("/"));
			if (target !== null && ++hops <= 40) {
				if (target.startsWith("/")) parts.length = 0;
				pending.unshift(...target.split("/").filter(Boolean));
				continue;
			}
			parts.push(part);
		}
		return "/" + parts.join("/");
	}
	const SIGNAL_NUMBERS = {
		HUP: 1,
		INT: 2,
		QUIT: 3,
		ILL: 4,
		TRAP: 5,
		ABRT: 6,
		BUS: 7,
		FPE: 8,
		KILL: 9,
		USR1: 10,
		SEGV: 11,
		USR2: 12,
		PIPE: 13,
		ALRM: 14,
		TERM: 15,
		CHLD: 17,
		CONT: 18,
		STOP: 19,
		TSTP: 20,
		WINCH: 28
	};
	const SIGNAL_NAMES = {
		1: "Hangup",
		2: "Interrupt",
		3: "Quit",
		6: "Aborted",
		9: "Killed",
		10: "User defined signal 1",
		12: "User defined signal 2",
		13: "Broken pipe",
		14: "Alarm clock",
		15: "Terminated"
	};
	const SHELL_BUILTINS = /* @__PURE__ */ new Set([
		"echo",
		"printf",
		"kill",
		"test",
		"[",
		"pwd",
		"read",
		"true",
		"false",
		"type",
		"command",
		"ulimit",
		"umask",
		"wait",
		"jobs",
		"fg",
		"bg",
		"help",
		"history",
		"times"
	]);
	const KEYWORDS = /* @__PURE__ */ new Set([
		"if",
		"then",
		"else",
		"elif",
		"fi",
		"case",
		"esac",
		"for",
		"select",
		"while",
		"until",
		"do",
		"done",
		"in",
		"function",
		"time",
		"{",
		"}",
		"!",
		"[[",
		"]]",
		"coproc"
	]);
	const BUILTINS = {
		":": noop,
		true: noop,
		false: async () => 1,
		async wait(args, io) {
			const ids = args.filter((arg) => !arg.startsWith("-"));
			if (args.includes("-n")) {
				const pending = (ids.length ? ids.map((id) => this.job(id)) : [...this.state.jobs.values()]).filter((job) => job !== void 0 && job.status === void 0);
				if (!pending.length) return 127;
				const [job, status] = await Promise.race(pending.map((job) => job.promise.then((status) => [job, status])));
				this.reap(job, io);
				return status;
			}
			if (!ids.length) {
				for (const job of [...this.state.jobs.values()]) {
					await job.promise;
					this.reap(job, io);
				}
				return 0;
			}
			let status = 0;
			for (const id of ids) {
				const job = this.job(id);
				if (!job) {
					io.stderr.write("bash: wait: " + (id.startsWith("%") ? id + ": no such job" : "pid " + id + " is not a child of this shell") + "\n");
					status = 127;
					continue;
				}
				status = await job.promise;
				this.reap(job, io);
			}
			return status;
		},
		async jobs(args, io) {
			const pids = args.includes("-p");
			const long = args.includes("-l");
			const running = args.includes("-r");
			const stopped = args.includes("-s");
			const jobs = [...this.state.jobs.values()].sort((a, b) => a.id - b.id);
			jobs.forEach((job, index) => {
				if (stopped || running && job.status !== void 0 || job.status !== void 0 && (job.signal === 2 || job.signal === 13 || job.signal === 15)) return;
				if (pids) {
					io.stdout.write(job.pid + "\n");
					return;
				}
				const mark = index === jobs.length - 1 ? "+" : index === jobs.length - 2 ? "-" : " ";
				const state = job.status === void 0 ? "Running" : job.signal ? SIGNAL_NAMES[job.signal] ?? "Killed" : job.status ? "Exit " + job.status : "Done";
				io.stdout.write("[" + job.id + "]" + mark + "  " + (long ? job.pid + " " : "") + state.padEnd(24) + job.source + (job.status === void 0 ? " &" : "") + "\n");
			});
			for (const job of jobs) if (job.status !== void 0 && !pids) this.state.jobs.delete(job.pid);
			return 0;
		},
		async kill(args, io) {
			if (args[0] === "-l" || args[0] === "-L") {
				const handler = this.host.commands.get("kill");
				return handler ? this.external("kill", handler, args, io) : 0;
			}
			let signal = 15;
			let i = 0;
			const parse = (name) => {
				if (/^\d+$/.test(name)) return Number(name);
				const upper = name.toUpperCase().replace(/^SIG/, "");
				const number = Object.entries(SIGNAL_NUMBERS).find(([key]) => key === upper)?.[1];
				if (number === void 0) throw new CommandError(name + ": invalid signal specification");
				return number;
			};
			if (args[0] === "-s" || args[0] === "-n") {
				signal = parse(args[1] ?? "");
				i = 2;
			} else if (args[0]?.startsWith("-") && args[0] !== "--" && args[0] !== "-") {
				signal = parse(args[0].slice(1));
				i = 1;
			}
			if (args[i] === "--") i++;
			const targets = args.slice(i);
			if (!targets.length) throw new CommandError("usage: kill [-s sigspec | -n signum | -sigspec] pid | jobspec ... or kill -l [sigspec]", 2);
			let status = 0;
			for (const target of targets) {
				const job = this.job(target);
				if (job) {
					if (job.status !== void 0) {
						if (target.startsWith("%")) {
							io.stderr.write("bash: kill: " + target + ": no such job\n");
							status = 1;
						}
						continue;
					}
					if (signal === 0 || signal === 18 || signal === 19 || signal === 20) continue;
					job.signal = signal;
					job.controller.abort(new KillSignal(128 + signal));
					continue;
				}
				if (target === "1" || target === "$$") {
					if (signal === 0 || signal === 18 || signal === 19 || signal === 20 || signal === 13 || signal === 17 || signal === 28) continue;
					throw new ExitSignal(128 + signal);
				}
				if (!/^-?\d+$/.test(target) && !target.startsWith("%")) {
					io.stderr.write("bash: kill: " + target + ": arguments must be process or job IDs\n");
					status = 1;
					continue;
				}
				io.stderr.write("bash: kill: " + (target.startsWith("%") ? target + ": no such job" : "(" + target + ") - No such process") + "\n");
				status = 1;
			}
			return status;
		},
		alias: noop,
		unalias: noop,
		hash: noop,
		ulimit: noop,
		async disown(args) {
			const ids = args.filter((arg) => !arg.startsWith("-") || /^-\d/.test(arg));
			const jobs = args.includes("-a") ? [...this.state.jobs.values()] : ids.length ? ids.map((id) => this.job(id)) : [this.job("%%")];
			let status = 0;
			for (const job of jobs) if (job) this.state.jobs.delete(job.pid);
			else status = 1;
			return status;
		},
		async cd(args, io) {
			const target = args.filter((arg) => arg !== "-P" && arg !== "-L")[0] ?? this.get("HOME") ?? "/";
			const destination = target === "-" ? this.get("OLDPWD") ?? this.state.cwd : target;
			const logical = this.resolve(destination);
			const stat = await this.host.fs.stat(logical);
			if (!stat) throw new CommandError(target + ": No such file or directory");
			const path = args.includes("-P") ? await physical(this.host.fs, logical) : logical;
			if (stat.kind !== "directory") throw new CommandError(target + ": Not a directory");
			this.set("OLDPWD", this.state.cwd);
			this.state.cwd = path;
			this.set("PWD", path);
			if (target === "-") io.stdout.write(path + "\n");
			return 0;
		},
		async trap(args, io) {
			if (!args.length || args[0] === "-p") {
				for (const [signal, action] of this.state.traps) if (args.length < 2 || args.includes(signal)) io.stdout.write("trap -- " + shellQuote(action) + " " + signal + "\n");
				return 0;
			}
			if (args[0] === "-l") return 0;
			const rest = args[0] === "--" ? args.slice(1) : args;
			const reset = rest.length === 1 || /^(-|\d+)$/.test(rest[0]) && rest[0] !== "0";
			const action = reset ? "-" : rest[0];
			for (const raw of reset && rest[0] !== "-" ? rest : rest.slice(1)) {
				let signal = raw.toUpperCase().replace(/^SIG/, "");
				if (signal === "0") signal = "EXIT";
				if (action === "-") this.state.traps.delete(signal);
				else this.state.traps.set(signal, action);
			}
			return 0;
		},
		async shopt(args, io) {
			let mode = "";
			const names = [];
			for (const arg of args) if (/^-[supqo]+$/.test(arg)) mode = arg.replace(/[op-]/g, "").slice(-1) || mode;
			else names.push(arg);
			if (mode === "s" || mode === "u") {
				for (const name of names) if (mode === "s") this.state.shopt.add(name);
				else this.state.shopt.delete(name);
				return 0;
			}
			let status = 0;
			for (const name of names.length ? names : [
				"dotglob",
				"extglob",
				"failglob",
				"globstar",
				"nocaseglob",
				"nocasematch",
				"nullglob"
			]) {
				const on = this.state.shopt.has(name);
				if (!on) status = 1;
				if (mode !== "q") io.stdout.write(name.padEnd(15) + "	" + (on ? "on" : "off") + "\n");
			}
			return status;
		},
		async getopts(args, io) {
			const [spec, name, ...rest] = args;
			if (spec === void 0 || name === void 0) throw new CommandError("usage: getopts optstring name [arg ...]", 2);
			const argv = rest.length ? rest : this.state.positional;
			const silent = spec.startsWith(":");
			const letters = silent ? spec.slice(1) : spec;
			let index = Number(this.get("OPTIND") ?? "1") || 1;
			if (index !== this.state.optind) this.state.optpos = 1;
			const arg = argv[index - 1];
			this.state.vars.delete("OPTARG");
			if (arg === void 0 || arg === "-" || !arg.startsWith("-") || arg === "--") {
				if (arg === "--") index++;
				this.state.optind = index;
				this.state.optpos = 1;
				this.set("OPTIND", String(index));
				this.set(name, "?");
				return 1;
			}
			const letter = arg[this.state.optpos] ?? "";
			let next = this.state.optpos + 1;
			const position = letter === ":" ? -1 : letters.indexOf(letter);
			if (position < 0) {
				this.set(name, "?");
				if (silent) this.set("OPTARG", letter);
				else io.stderr.write("bash: illegal option -- " + letter + "\n");
			} else if (letters[position + 1] === ":") {
				if (next < arg.length) {
					this.set("OPTARG", arg.slice(next));
					this.set(name, letter);
				} else if (argv[index] !== void 0) {
					this.set("OPTARG", argv[index]);
					this.set(name, letter);
					index++;
				} else if (silent) {
					this.set(name, ":");
					this.set("OPTARG", letter);
				} else {
					io.stderr.write("bash: option requires an argument -- " + letter + "\n");
					this.set(name, "?");
				}
				next = arg.length;
			} else this.set(name, letter);
			if (next >= arg.length) {
				index++;
				next = 1;
			}
			this.state.optpos = next;
			this.state.optind = index;
			this.set("OPTIND", String(index));
			return 0;
		},
		async pushd(args, io) {
			const target = args.find((arg) => !arg.startsWith("-") || arg === "-");
			const previous = this.state.cwd;
			if (target === void 0) {
				const top = this.state.stack.shift();
				if (top === void 0) throw new CommandError("no other directory");
				await BUILTINS.cd.call(this, [top], {
					...io,
					stdout: this.buffer()
				});
			} else {
				const status = await BUILTINS.cd.call(this, [target], {
					...io,
					stdout: this.buffer()
				});
				if (status) return status;
			}
			this.state.stack.unshift(previous);
			io.stdout.write([this.state.cwd, ...this.state.stack].join(" ") + "\n");
			return 0;
		},
		async popd(_args, io) {
			const top = this.state.stack.shift();
			if (top === void 0) throw new CommandError("directory stack empty");
			await BUILTINS.cd.call(this, [top], {
				...io,
				stdout: this.buffer()
			});
			io.stdout.write([this.state.cwd, ...this.state.stack].join(" ") + "\n");
			return 0;
		},
		async dirs(_args, io) {
			io.stdout.write([this.state.cwd, ...this.state.stack].join(" ") + "\n");
			return 0;
		},
		async pwd(args, io) {
			io.stdout.write((args.includes("-P") ? await physical(this.host.fs, this.state.cwd) : this.state.cwd) + "\n");
			return 0;
		},
		async umask(args, io) {
			const symbolic = args.includes("-S");
			const value = args.find((arg) => !arg.startsWith("-"));
			if (value === void 0) {
				const mask = this.state.umask;
				if (!symbolic) io.stdout.write(mask.toString(8).padStart(4, "0") + "\n");
				else io.stdout.write([
					"u",
					"g",
					"o"
				].map((who, index) => who + "=" + [
					"r",
					"w",
					"x"
				].filter((_, bit) => !(mask >> (2 - index) * 3 & 4 >> bit)).join("")).join(",") + "\n");
				return 0;
			}
			if (/^[0-7]{1,4}$/.test(value)) {
				this.state.umask = parseInt(value, 8);
				return 0;
			}
			if (/^\d+$/.test(value)) throw new CommandError(value + ": octal number out of range");
			let allowed = 511 & ~this.state.umask;
			for (const clause of value.split(",")) {
				const match = clause.match(/^([ugoa]*)([-+=])([rwx]*)$/);
				if (!match) throw new CommandError("`" + clause.slice(-1) + "': invalid symbolic mode operator");
				const who = match[1] === "" || match[1].includes("a") ? 511 : (match[1].includes("u") ? 448 : 0) | (match[1].includes("g") ? 56 : 0) | (match[1].includes("o") ? 7 : 0);
				const perm = (match[3].includes("r") ? 292 : 0) | (match[3].includes("w") ? 146 : 0) | (match[3].includes("x") ? 73 : 0);
				if (match[2] === "+") allowed |= perm & who;
				else if (match[2] === "-") allowed &= ~(perm & who);
				else allowed = allowed & ~who | perm & who;
			}
			this.state.umask = 511 & ~allowed;
			if (symbolic) io.stdout.write([
				"u",
				"g",
				"o"
			].map((who, index) => who + "=" + [
				"r",
				"w",
				"x"
			].filter((_, bit) => allowed >> (2 - index) * 3 & 4 >> bit).join("")).join(",") + "\n");
			return 0;
		},
		async unset(args) {
			let functions = false;
			let refs = false;
			for (let arg of args) if (arg === "-f") functions = true;
			else if (arg === "-v") functions = false;
			else if (arg === "-n") refs = true;
			else if (functions) this.state.functions.delete(arg);
			else if (refs && this.state.refs.has(arg)) this.state.refs.delete(arg);
			else {
				arg = this.target(arg);
				const element = arg.match(/^([A-Za-z_][A-Za-z0-9_]*)\[(.*)\]$/);
				if (element) {
					const map = this.state.maps.get(element[1]);
					if (map) {
						map.delete(element[2]);
						continue;
					}
					const array = this.state.vars.get(element[1])?.slice();
					if (array) {
						const index = Number(evaluateArith(element[2], {
							get: (n) => this.get(n) ?? "",
							set: () => void 0
						}));
						delete array[index < 0 ? array.length + index : index];
						this.state.vars.set(element[1], array);
					}
					continue;
				}
				if (this.state.readonly.has(arg)) throw new CommandError(arg + ": cannot unset: readonly variable");
				this.state.maps.delete(arg);
				this.state.vars.delete(arg);
				this.state.exported.delete(arg);
			}
			return 0;
		},
		async set(args, io) {
			if (!args.length) {
				for (const [name, value] of [...this.state.vars].sort(([a], [b]) => a < b ? -1 : 1)) io.stdout.write(name + "=" + (value[0] ?? "") + "\n");
				return 0;
			}
			const options = {
				e: "errexit",
				u: "nounset",
				x: "xtrace",
				f: "noglob",
				C: "noclobber",
				errexit: "errexit",
				nounset: "nounset",
				xtrace: "xtrace",
				pipefail: "pipefail",
				noglob: "noglob",
				noclobber: "noclobber"
			};
			for (let i = 0; i < args.length; i++) {
				const arg = args[i];
				if (arg === "--" || arg === "-") {
					this.state.positional = args.slice(i + 1);
					return 0;
				}
				if (!/^[-+]/.test(arg)) {
					this.state.positional = args.slice(i);
					return 0;
				}
				const enable = arg[0] === "-";
				for (const flag of arg.slice(1)) if (flag === "o") {
					const name = args[++i];
					if (name === void 0) {
						for (const [key, value] of Object.entries(this.state.options)) io.stdout.write(key.padEnd(15) + (value ? "on" : "off") + "\n");
						continue;
					}
					if (options[name]) this.state.options[options[name]] = enable;
					else if (![
						"posix",
						"vi",
						"emacs",
						"monitor",
						"notify",
						"allexport",
						"hashall",
						"braceexpand",
						"history",
						"ignoreeof",
						"verbose",
						"nolog",
						"physical",
						"functrace",
						"errtrace",
						"noexec",
						"keyword",
						"onecmd",
						"privileged",
						"interactive-comments"
					].includes(name)) throw new CommandError(name + ": invalid option name", 2);
				} else if (options[flag]) this.state.options[options[flag]] = enable;
			}
			return 0;
		},
		async shift(args) {
			const n = count$1(args[0], 1);
			if (n > this.state.positional.length || n < 0) return 1;
			this.state.positional = this.state.positional.slice(n);
			return 0;
		},
		async read(args, io) {
			let source = io.stdin;
			let raw = false;
			let delimiter = "\n";
			let array;
			let chars;
			const names = [];
			for (let i = 0; i < args.length; i++) {
				const arg = args[i];
				if (/^-[a-zA-Z]/.test(arg) && !names.length) for (let j = 1; j < arg.length; j++) {
					const flag = arg[j];
					const value = () => j + 1 < arg.length ? arg.slice(j + 1) : args[++i];
					if (flag === "r") raw = true;
					else if (flag === "s") continue;
					else if (flag === "a") {
						array = value();
						break;
					} else if (flag === "d") {
						delimiter = value() ?? "";
						break;
					} else if (flag === "n" || flag === "N") {
						chars = Number(value());
						break;
					} else if (flag === "u") {
						const fd = Number(value());
						const found = fd === 0 ? io.stdin : io.fds?.get(fd)?.input;
						if (!found) {
							io.stderr.write("bash: read: " + fd + ": invalid file descriptor: Bad file descriptor\n");
							return 1;
						}
						source = found;
						break;
					} else if (flag === "p" || flag === "t") {
						value();
						break;
					}
				}
				else names.push(arg);
			}
			let line;
			if (chars !== void 0) {
				const text = await source.readChars(chars);
				line = text ? {
					text,
					complete: true
				} : null;
			} else line = await source.readLine(delimiter);
			const targets = names.length ? names : array ? [] : ["REPLY"];
			if (!line) {
				for (const name of targets) this.set(name, "");
				if (array) this.set(array, []);
				return 1;
			}
			let text = line.text;
			if (!raw && text.includes("\\")) text = text.replace(/\\([\s\S])/g, "$1");
			const ifs = this.state.vars.has("IFS") ? this.get("IFS") : " 	\n";
			if (array) this.set(array, readFields(text, Number.MAX_SAFE_INTEGER, ifs).filter((field, index, all) => field !== "" || index < all.length - 1));
			if (targets.length === 1 && !names.length) this.set("REPLY", line.text);
			else {
				const fields = readFields(text, targets.length, ifs);
				targets.forEach((name, index) => this.set(name, fields[index] ?? ""));
			}
			return line.complete ? 0 : 1;
		},
		async mapfile(args, io) {
			let strip = false;
			let delimiter = "\n";
			let name = "MAPFILE";
			let callback;
			let quantum = 5e3;
			let skip = 0;
			let limit = 0;
			let origin;
			let source = io.stdin;
			for (let i = 0; i < args.length; i++) {
				const arg = args[i];
				if (arg === "-t") strip = true;
				else if (arg === "-d") delimiter = args[++i] ?? "\n";
				else if (arg === "-C") callback = args[++i];
				else if (arg === "-c") quantum = Number(args[++i] ?? 5e3) || 5e3;
				else if (arg === "-s") skip = Number(args[++i] ?? 0);
				else if (arg === "-n") limit = Number(args[++i] ?? 0);
				else if (arg === "-O") origin = Number(args[++i] ?? 0);
				else if (arg === "-u") {
					const fd = Number(args[++i]);
					const found = fd === 0 ? io.stdin : io.fds?.get(fd)?.input;
					if (!found) {
						io.stderr.write("bash: mapfile: " + fd + ": invalid file descriptor: Bad file descriptor\n");
						return 1;
					}
					source = found;
				} else if (arg.startsWith("-")) i++;
				else name = arg;
			}
			if (delimiter === "") delimiter = "\0";
			const values = origin !== void 0 ? this.state.vars.get(name)?.slice() ?? [] : [];
			let index = origin ?? 0;
			let read = 0;
			for (let line = await source.readLine(delimiter); line; line = limit && read >= limit ? null : await source.readLine(delimiter)) {
				if (skip > 0) {
					skip--;
					continue;
				}
				const value = strip || !line.complete ? line.text : line.text + delimiter;
				if (callback !== void 0 && read % quantum === quantum - 1) {
					if (await BUILTINS.eval.call(this, [
						callback,
						String(index),
						shellQuote(value)
					], io) === 2) return 1;
				}
				values[index++] = value;
				read++;
				if (limit && read >= limit) break;
			}
			this.set(name, Array.from(values, (value) => value ?? ""));
			return 0;
		},
		async eval(args, io) {
			const source = args.join(" ");
			let script;
			try {
				script = parse(source);
			} catch (error) {
				if (!(error instanceof SyntaxError)) throw error;
				io.stderr.write("bash: eval: " + error.message + "\n");
				return 2;
			}
			this.enter();
			try {
				return await this.script(script, io);
			} finally {
				this.leave();
			}
		},
		async source(args, io) {
			if (!args.length) throw new CommandError("filename argument required", 2);
			return this.source(this.resolve(args[0]), args.slice(1), io, false, void 0, args[0]);
		},
		async exit(args) {
			throw new ExitSignal(args.length ? count$1(args[0], 0) & 255 : this.state.status);
		},
		async return(args) {
			throw new ReturnSignal(args.length ? count$1(args[0], 0) & 255 : this.state.status);
		},
		async break(args) {
			throw new LoopSignal("break", count$1(args[0], 1));
		},
		async continue(args) {
			throw new LoopSignal("continue", count$1(args[0], 1));
		},
		async let(args) {
			let value = 0;
			for (const arg of args) value = await this.arith([{
				type: "text",
				value: arg,
				quoted: true
			}], {
				stdin: new Input(),
				stdout: this.buffer(),
				stderr: this.buffer()
			});
			return value === 0 ? 1 : 0;
		},
		async test(args, io) {
			return this.test(args.map((text) => ({ text })), false, io);
		},
		async "["(args, io) {
			if (args[args.length - 1] !== "]") {
				io.stderr.write("bash: [: missing `]'\n");
				return 2;
			}
			return this.test(args.slice(0, -1).map((text) => ({ text })), false, io);
		},
		async type(args, io) {
			let status = 0;
			const flags = args.filter((arg) => /^-[atpPf]+$/.test(arg)).join("");
			const terse = flags.includes("t");
			const every = flags.includes("a");
			const forced = flags.includes("P");
			const paths = flags.includes("p") || forced;
			for (const name of args.filter((arg) => !arg.startsWith("-"))) {
				const kinds = [];
				if (forced) {
					if (this.host.commands.has(name) || [
						"[",
						"echo",
						"false",
						"kill",
						"printf",
						"pwd",
						"test",
						"true"
					].includes(name)) io.stdout.write("/usr/bin/" + name + "\n");
					else status = 1;
					continue;
				}
				if (KEYWORDS.has(name)) kinds.push("keyword");
				if (this.state.functions.has(name)) kinds.push("function");
				if (BUILTINS[name] || SHELL_BUILTINS.has(name) || DECLARATIONS.has(name)) kinds.push("builtin");
				if (this.host.commands.has(name) || every && [
					"[",
					"echo",
					"false",
					"kill",
					"printf",
					"pwd",
					"test",
					"true"
				].includes(name)) kinds.push("file");
				if (!kinds.length) {
					if (!terse) io.stderr.write("bash: type: " + name + ": not found\n");
					status = 1;
					continue;
				}
				for (const kind of every ? kinds : kinds.slice(0, 1)) {
					if (paths) {
						if (kind === "file") io.stdout.write("/usr/bin/" + name + "\n");
						continue;
					}
					if (terse) io.stdout.write(kind + "\n");
					else if (kind === "file") for (const dir of every ? ["/usr/bin/", "/bin/"] : ["/usr/bin/"]) io.stdout.write(name + " is " + dir + name + "\n");
					else io.stdout.write(kind === "function" ? name + " is a function\n" + functionText(name, this.state.functions.get(name)) + "\n" : kind === "builtin" ? name + " is a shell builtin\n" : name + " is a shell keyword\n");
				}
			}
			return status;
		},
		async command(args, io) {
			if (args[0] === "-V") return BUILTINS.type.call(this, args.slice(1), io);
			if (args[0] === "-v") {
				let status = 0;
				for (const name of args.slice(1)) if (this.state.functions.has(name) || BUILTINS[name] || SHELL_BUILTINS.has(name) || DECLARATIONS.has(name) || KEYWORDS.has(name)) io.stdout.write(name + "\n");
				else if (this.host.commands.has(name)) io.stdout.write("/usr/bin/" + name + "\n");
				else status = 1;
				return status;
			}
			if (!args.length) return 0;
			return this.dispatch(args, io, false);
		},
		async builtin(args, io) {
			const builtin = args.length ? BUILTINS[args[0]] : void 0;
			if (!builtin) throw new CommandError((args[0] ?? "") + ": not a shell builtin");
			return builtin.call(this, args.slice(1), io);
		},
		async which(args, io) {
			let status = 0;
			for (const name of args.filter((arg) => !arg.startsWith("-"))) if (this.host.commands.has(name) || BUILTINS[name]) io.stdout.write("/usr/bin/" + name + "\n");
			else status = 1;
			return status;
		},
		async exec(args, io) {
			if (!args.length) return 0;
			throw new ExitSignal(await this.dispatch(args, io));
		},
		async env(args, io) {
			const assigns = [];
			let clear = false;
			let i = 0;
			for (; i < args.length; i++) if (args[i] === "-i" || args[i] === "-") clear = true;
			else if (args[i] === "-u") assigns.push([args[++i], "\0"]);
			else if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(args[i])) {
				const eq = args[i].indexOf("=");
				assigns.push([args[i].slice(0, eq), args[i].slice(eq + 1)]);
			} else break;
			const command = args.slice(i);
			return this.subshell(async () => {
				if (clear) {
					for (const name of this.state.exported) this.state.vars.delete(name);
					this.state.exported.clear();
				}
				for (const [name, value] of assigns) if (value === "\0") {
					this.state.vars.delete(name);
					this.state.exported.delete(name);
				} else {
					this.set(name, value);
					this.state.exported.add(name);
				}
				if (!command.length) {
					for (const [name, value] of Object.entries(this.environment())) io.stdout.write(name + "=" + value + "\n");
					return 0;
				}
				return this.dispatch(command, io, false);
			});
		},
		async printenv(args, io) {
			const env = this.environment();
			if (!args.length) {
				for (const [name, value] of Object.entries(env)) io.stdout.write(name + "=" + value + "\n");
				return 0;
			}
			let status = 0;
			for (const name of args) if (name in env) io.stdout.write(env[name] + "\n");
			else status = 1;
			return status;
		},
		async printf(args, io) {
			if (args[0] === "-v" && args.length >= 2) {
				const handler = this.host.commands.get("printf");
				if (!handler) return 1;
				const out = this.buffer();
				const status = await this.external("printf", handler, args.slice(2), {
					...io,
					stdout: out
				});
				const element = /^([A-Za-z_][A-Za-z0-9_]*)\[(.*)\]$/.exec(args[1]);
				if (element) await this.assign({
					name: element[1],
					index: [{
						type: "text",
						value: element[2],
						quoted: true
					}],
					value: [{
						type: "text",
						value: out.text(),
						quoted: true
					}],
					append: false
				}, io);
				else this.set(args[1], out.text());
				return status;
			}
			const handler = this.host.commands.get("printf");
			return handler ? this.external("printf", handler, args, io) : 127;
		},
		async bash(args, io) {
			const options = [];
			let i = 0;
			for (; i < args.length && /^[-+][a-zA-Z]+$/.test(args[i]); i++) options.push(args[i]);
			const command = options.some((option) => option.includes("c"));
			const flags = options.map((option) => option.replace(/[cl]/g, "")).filter((option) => option.length > 1);
			return this.subshell(async () => {
				if (flags.length) await BUILTINS.set.call(this, flags, io);
				if (command) {
					const source = args[i] ?? "";
					let script;
					try {
						script = parse(source);
					} catch (error) {
						if (!(error instanceof SyntaxError)) throw error;
						io.stderr.write("bash: -c: " + error.message + "\n");
						return 2;
					}
					if (args[i + 1] !== void 0) this.state.arg0 = args[i + 1];
					this.state.positional = args.slice(i + 2);
					this.enter();
					try {
						return await this.script(script, io);
					} finally {
						this.leave();
					}
				}
				if (i >= args.length) {
					const source = await io.stdin.text();
					this.enter();
					try {
						return await this.script(parse(source), io);
					} finally {
						this.leave();
					}
				}
				return this.source(this.resolve(args[i]), args.slice(i + 1), io, false, args[i]);
			}, io);
		},
		async timeout(args, io) {
			let i = 0;
			let preserve = false;
			while (i < args.length && args[i].startsWith("-") && args[i] !== "-") {
				if (args[i] === "--preserve-status") preserve = true;
				i += args[i] === "-s" || args[i] === "-k" ? 2 : 1;
			}
			const match = /^(\d*\.?\d+)([smhd]?)$/.exec(args[i] ?? "");
			const command = args.slice(i + 1);
			if (!match || !command.length) throw new CommandError(match ? "missing operand" : "invalid time interval '" + (args[i] ?? "") + "'", 125);
			const ms = Number(match[1]) * {
				"": 1,
				s: 1,
				m: 60,
				h: 3600,
				d: 86400
			}[match[2]] * 1e3;
			if (ms === 0) return this.dispatch(command, io);
			const controller = new AbortController();
			const runner = this.fork(this.state, AbortSignal.any([this.signal, controller.signal]));
			let timer;
			const expired = new Promise((resolve) => {
				timer = setTimeout(() => {
					controller.abort("timed out");
					resolve(preserve ? 143 : 124);
				}, ms);
			});
			try {
				const ran = runner.dispatch(command, io).catch((error) => {
					if (controller.signal.aborted && !this.signal.aborted) return preserve ? 143 : 124;
					throw error;
				});
				return await Promise.race([ran, expired]);
			} finally {
				if (timer !== void 0) clearTimeout(timer);
				this.check();
			}
		},
		async time(args, io) {
			const start = Date.now();
			const status = args.length ? await this.dispatch(args, io) : 0;
			io.stderr.write("\nreal	" + ((Date.now() - start) / 1e3).toFixed(3) + "s\nuser	0.000s\nsys	0.000s\n");
			return status;
		}
	};
	BUILTINS["."] = BUILTINS.source;
	BUILTINS.readarray = BUILTINS.mapfile;
	BUILTINS.sh = BUILTINS.bash;
	// src/bash/internal/Prune.ts
	function inside(path, point) {
		return path === point || path.startsWith(point + "/");
	}
	const AHEAD = 64;
	const AHEAD_BYTES = 16 << 20;
	function ahead(items, load) {
		const slots = /* @__PURE__ */ new Map();
		const sizes = /* @__PURE__ */ new Map();
		let next = 0;
		let width = 2;
		let held = 0;
		const start = (index) => {
			const promise = load(items[index]);
			if (promise) promise.then((bytes) => {
				if (!slots.has(index)) return;
				sizes.set(index, bytes.length);
				held += bytes.length;
			}, () => {});
			slots.set(index, promise);
		};
		return (index) => {
			if (index >= next) {
				start(index);
				next = index + 1;
			}
			const promise = slots.get(index) ?? null;
			slots.delete(index);
			held -= sizes.get(index) ?? 0;
			sizes.delete(index);
			for (; next < items.length && next <= index + width && held < AHEAD_BYTES; next++) start(next);
			width = Math.min(width * 2, AHEAD);
			return promise;
		};
	}
	async function pruned(fs, root, literals, exact) {
		const matched = exact && fs.matches ? await fs.matches(root, exact.literals, exact.ignoreCase) : null;
		if (!matched && (!literals || !fs.search)) return null;
		const files = matched ?? await fs.search(root, literals);
		if (!files) return null;
		const tree = /* @__PURE__ */ new Map([[root, /* @__PURE__ */ new Set()]]);
		if (matched) tree.exact = true;
		for (const file of files) {
			if (!inside(file, root === "/" ? "" : root) || file === root) continue;
			let child = file;
			for (let parent = child.slice(0, child.lastIndexOf("/")) || "/";; child = parent, parent = parent.slice(0, parent.lastIndexOf("/")) || "/") {
				let names = tree.get(parent);
				const seen = names !== void 0;
				if (!names) tree.set(parent, names = /* @__PURE__ */ new Set());
				names.add(child.slice(child.lastIndexOf("/") + 1));
				if (seen || parent === root) break;
			}
		}
		return tree;
	}
	function prunedList(tree, path) {
		return [...tree.get(path) ?? []].sort();
	}
	function prunedStat(tree, path) {
		return tree.has(path) ? {
			kind: "directory",
			size: 0,
			mtime: 0,
			mode: 365
		} : {
			kind: "file",
			size: 0,
			mtime: 0,
			mode: 292
		};
	}
	function exactLiterals(patterns, syntax) {
		const out = [];
		const special = syntax === "fixed" ? null : syntax === "basic" ? /[.[\]*^$\\]/ : /[.[\]*^$\\+?(){}|]/;
		for (const pattern of patterns) {
			const branches = syntax === "fixed" ? [pattern] : syntax === "basic" ? pattern.split("\\|") : pattern.split("|");
			for (const branch of branches) {
				if (!branch || branch.includes("\n") || special && special.test(branch)) return null;
				out.push(branch);
			}
		}
		return out.length ? out : null;
	}
	function literals(patterns, syntax) {
		const out = [];
		for (const pattern of patterns) {
			const found = syntax === "fixed" ? pattern ? [pattern] : null : branches(pattern, syntax);
			if (!found) return null;
			out.push(...found);
		}
		return out.length ? out : null;
	}
	function branches(pattern, syntax) {
		const basic = syntax === "basic";
		const out = [];
		let best = "";
		let run = "";
		const cut = () => {
			if (run.length > best.length) best = run;
			run = "";
		};
		const end = () => {
			cut();
			if (!best) return false;
			out.push(best);
			best = "";
			return true;
		};
		const quantified = () => {
			run = run.slice(0, -1);
			cut();
		};
		for (let i = 0; i < pattern.length; i++) {
			const c = pattern[i];
			if (c === "\\") {
				const next = pattern[i + 1];
				i++;
				if (next === void 0) return null;
				if (basic && next === "|") {
					if (!end()) return null;
					continue;
				}
				if (basic && next === "(") {
					i = group(pattern, i + 1, true);
					if (i < 0) return null;
					cut();
					continue;
				}
				if (basic && (next === "?" || next === "+" || next === "{")) {
					if (next === "{") i = pattern.indexOf("\\}", i) + 1 || pattern.length;
					quantified();
					continue;
				}
				if (/[A-Za-z0-9]/.test(next)) {
					cut();
					i = escape(pattern, i, next);
					continue;
				}
				if (syntax !== "perl" && "<>'`".includes(next)) {
					cut();
					continue;
				}
				run += next;
				continue;
			}
			if (c === "*") {
				quantified();
				continue;
			}
			if (!basic && (c === "?" || c === "+")) {
				quantified();
				continue;
			}
			if (!basic && c === "{" && /^\{\d*(,\d*)?\}/.test(pattern.slice(i))) {
				i = pattern.indexOf("}", i);
				quantified();
				continue;
			}
			if (!basic && c === "|") {
				if (!end()) return null;
				continue;
			}
			if (!basic && c === "(") {
				i = group(pattern, i + 1, false, syntax === "perl");
				if (i < 0) return null;
				cut();
				continue;
			}
			if (c === "[") {
				i = bracket(pattern, i + 1, syntax === "perl");
				if (i < 0) return null;
				cut();
				continue;
			}
			if (c === "." || c === "^" || c === "$" || !basic && c === ")") {
				cut();
				continue;
			}
			run += c;
		}
		return end() ? out : null;
	}
	function group(pattern, start, basic, perl = false) {
		let depth = 1;
		for (let i = start; i < pattern.length; i++) {
			const c = pattern[i];
			if (c === "[") {
				i = bracket(pattern, i + 1, perl);
				if (i < 0) return -1;
				continue;
			}
			if (c === "\\") {
				const next = pattern[++i];
				if (basic && next === "(") depth++;
				if (basic && next === ")" && --depth === 0) return quantifier(pattern, i + 1, basic);
				continue;
			}
			if (!basic && c === "(") depth++;
			if (!basic && c === ")" && --depth === 0) return quantifier(pattern, i + 1, basic);
		}
		return -1;
	}
	function quantifier(pattern, i, basic) {
		const rest = pattern.slice(i);
		const match = basic ? /^(\*|\\[?+]|\\\{[^\\]*\\\})/.exec(rest) : /^([*?+]|\{\d*(,\d*)?\})\??/.exec(rest);
		return i - 1 + (match ? match[0].length : 0);
	}
	function bracket(pattern, start, perl) {
		let i = start;
		if (pattern[i] === "^") i++;
		if (pattern[i] === "]") i++;
		for (; i < pattern.length; i++) {
			if (pattern[i] === "[" && /[:.=]/.test(pattern[i + 1] ?? "")) {
				const close = pattern.indexOf(pattern[i + 1] + "]", i + 2);
				if (close < 0) return -1;
				i = close + 1;
				continue;
			}
			if (perl && pattern[i] === "\\" && pattern[i + 1] !== void 0) {
				i++;
				continue;
			}
			if (pattern[i] === "]") return i;
		}
		return -1;
	}
	function escape(pattern, i, letter) {
		const rest = pattern.slice(i + 1);
		const skip = /[pPxNk]/.test(letter) ? /^(\{[^}]*\}|<[^>]*>)/.exec(rest) : null;
		if (skip) return i + skip[0].length;
		if (letter === "x") return i + (/^[0-9a-fA-F]{0,2}/.exec(rest)?.[0].length ?? 0);
		if (letter === "u") return i + (/^[0-9a-fA-F]{0,4}/.exec(rest)?.[0].length ?? 0);
		if (letter === "c") return i + Math.min(1, rest.length);
		if (/[0-9]/.test(letter)) return i + (/^[0-9]*/.exec(rest)?.[0].length ?? 0);
		return i;
	}
	// src/bash/internal/commands/util.ts
	function options(args, spec) {
		const flags = /* @__PURE__ */ new Set();
		const values = /* @__PURE__ */ new Map();
		const operands = [];
		const add = (key, value) => values.set(key, [...values.get(key) ?? [], value]);
		for (let i = 0; i < args.length; i++) {
			const arg = args[i];
			if (arg === "--") {
				operands.push(...args.slice(i + 1));
				break;
			}
			if (arg.startsWith("--") && arg.length > 2) {
				const eq = arg.indexOf("=");
				const name = eq < 0 ? arg.slice(2) : arg.slice(2, eq);
				const key = spec.long?.[name];
				if (key === void 0) throw new CommandError("unrecognized option '" + arg + "'", 2);
				if (key === "") continue;
				if ((spec.values ?? "").includes(key) || key.length > 1) {
					const value = eq < 0 ? args[++i] : arg.slice(eq + 1);
					if (value === void 0) throw new CommandError("option '" + arg + "' requires an argument", 2);
					add(key, value);
				} else flags.add(key);
				continue;
			}
			if (arg.startsWith("-") && arg.length > 1) {
				if (spec.numeric && /^-\d+$/.test(arg)) {
					add("n", arg.slice(1));
					continue;
				}
				let valid = true;
				for (let j = 1; j < arg.length; j++) {
					const flag = arg[j];
					if ((spec.values ?? "").includes(flag)) {
						const value = j + 1 < arg.length ? arg.slice(j + 1) : args[++i];
						if (value === void 0) throw new CommandError("option requires an argument -- '" + flag + "'", 2);
						add(flag, value);
						break;
					}
					if (!(spec.flags ?? "").includes(flag)) {
						valid = false;
						break;
					}
					flags.add(flag);
				}
				if (!valid) throw new CommandError("invalid option -- '" + arg.slice(1) + "'", 2);
				continue;
			}
			operands.push(arg);
		}
		return {
			flags,
			values,
			operands
		};
	}
	function last(parsed, key) {
		const list = parsed.values.get(key);
		return list?.[list.length - 1];
	}
	function device(path, size = 65536) {
		if (path === "/dev/null") return "";
		if (path === "/dev/zero") return "\0".repeat(size);
		if (path !== "/dev/urandom" && path !== "/dev/random") return void 0;
		const bytes = new Uint8Array(size);
		for (let done = 0; done < size; done += 65536) crypto.getRandomValues(bytes.subarray(done, Math.min(size, done + 65536)));
		return decode(bytes);
	}
	async function readInput(ctx, operand, size) {
		if (operand === "-" || operand === "/dev/stdin" || operand === "/dev/fd/0") return ctx.stdin.text();
		const path = ctx.resolve(operand);
		const stat = size === void 0 ? await ctx.fs.stat(path) : null;
		const special = size !== void 0 || !stat ? device(path, size) : void 0;
		if (special !== void 0) return special;
		if (stat) budget(ctx.limits, 2 * stat.size, ctx.name + ": " + operand);
		return decode(await ctx.fs.read(path));
	}
	async function eachInput(ctx, operands, visit, size) {
		let status = 0;
		for (const operand of operands.length ? operands : ["-"]) {
			let text;
			try {
				text = await readInput(ctx, operand, size);
			} catch (error) {
				if (!(error instanceof FsError)) throw error;
				ctx.stderr.write(ctx.name + ": " + operand + ": " + (error.code === "ENOENT" ? "No such file or directory" : error.code === "EISDIR" ? "Is a directory" : error.message) + "\n");
				status = 1;
				continue;
			}
			await visit(text, operand);
		}
		return status;
	}
	const SLICE = 65536;
	let yielded = 0;
	async function pause(ctx) {
		if (ctx.stdout.backlog) await ctx.stdout.drain();
		const now = Date.now();
		if (now - yielded < 25) return;
		yielded = now;
		await new Promise((resolve) => setTimeout(resolve, 0));
		if (ctx.signal.aborted) throw new CommandError("aborted", 124);
	}
	async function put(ctx, text) {
		if (text.length <= SLICE) {
			ctx.stdout.write(text);
			await pause(ctx);
			return;
		}
		for (let start = 0; start < text.length;) {
			let end = Math.min(text.length, start + SLICE);
			const code = text.charCodeAt(end - 1);
			if (end < text.length && code >= 55296 && code <= 56319) end++;
			ctx.stdout.write(text.slice(start, end));
			start = end;
			await pause(ctx);
		}
	}
	function batches(input, separator = "\n", limits) {
		let carry = "";
		return async () => {
			for (;;) {
				const chunk = await input.chunk();
				if (chunk === null) {
					const rest = carry;
					carry = "";
					return rest || null;
				}
				const tail = separator.length > 1 ? carry.slice(1 - separator.length) : "";
				const found = (tail + chunk).lastIndexOf(separator);
				const text = carry ? carry + chunk : chunk;
				if (found < 0) {
					if (limits && text.length > 1 << 20) budget(limits, 2 * text.length, "a line of " + text.length + " characters");
					carry = text;
					continue;
				}
				const end = carry.length - tail.length + found;
				carry = text.slice(end + separator.length);
				return end + separator.length === text.length ? text : text.slice(0, end + separator.length);
			}
		};
	}
	async function eachBatch(ctx, operands, visit, separator = "\n") {
		let status = 0;
		for (const operand of operands.length ? operands : ["-"]) {
			if (operand === "-" || operand === "/dev/stdin" || operand === "/dev/fd/0") {
				const next = batches(ctx.stdin, separator, ctx.limits);
				for (let text = await next(); text !== null; text = await next()) await visit(text, operand);
				continue;
			}
			let text;
			try {
				text = await readInput(ctx, operand);
			} catch (error) {
				if (!(error instanceof FsError)) throw error;
				ctx.stderr.write(ctx.name + ": " + operand + ": " + (error.code === "ENOENT" ? "No such file or directory" : error.code === "EISDIR" ? "Is a directory" : error.message) + "\n");
				status = 1;
				continue;
			}
			await visit(text, operand);
		}
		return status;
	}
	// src/bash/internal/commands/text.ts
	async function eachLine(ctx, operands, visit, terminate = false) {
		let carry = "";
		const status = await eachBatch(ctx, operands, async (batch) => {
			const text = carry ? carry + batch : batch;
			const cut = text.lastIndexOf("\n");
			carry = text.slice(cut + 1);
			if (cut < 0) return;
			let out = "";
			for (let start = 0; start <= cut;) {
				const end = text.indexOf("\n", start);
				out += visit(text.slice(start, end)) + "\n";
				start = end + 1;
				if (out.length < 65536) continue;
				await put(ctx, out);
				out = "";
			}
			await put(ctx, out);
		});
		if (carry) await put(ctx, visit(carry) + (terminate ? "\n" : ""));
		return status;
	}
	function count(value, fallback) {
		if (value === void 0) return fallback;
		const match = value.match(/^([+-]?\d+)([kKmMgGbB]?)$/);
		if (!match) throw new CommandError("invalid number: '" + value + "'");
		const scale = {
			"": 1,
			k: 1024,
			K: 1024,
			m: 1024 ** 2,
			M: 1024 ** 2,
			g: 1024 ** 3,
			G: 1024 ** 3,
			b: 512,
			B: 512
		}[match[2]];
		return Number(match[1]) * scale;
	}
	function lastLines(text, n) {
		let pos = text.length - 1;
		for (let k = 0; k < n && pos >= 0; k++) pos = text.lastIndexOf("\n", pos - 1);
		return pos < 0 ? text : text.slice(pos + 1);
	}
	async function headTail(ctx, tail) {
		const parsed = options(ctx.args, {
			flags: "qvfFz",
			values: "nc",
			numeric: true,
			long: {
				lines: "n",
				bytes: "c",
				quiet: "q",
				silent: "q",
				verbose: "v",
				follow: "f"
			}
		});
		const lineSpec = last(parsed, "n");
		const byteSpec = last(parsed, "c");
		const headers = (parsed.operands.length > 1 || parsed.flags.has("v")) && !parsed.flags.has("q");
		let first = true;
		const header = (name) => {
			if (!headers) return;
			ctx.stdout.write((first ? "" : "\n") + "==> " + (name === "-" ? "standard input" : name) + " <==\n");
			first = false;
		};
		const render = async (text) => {
			if (byteSpec !== void 0) {
				const n = count(byteSpec, 0);
				const bytes = encode(text);
				if (tail) await put(ctx, byteSpec.startsWith("+") ? decode(bytes.subarray(Math.max(0, n - 1))) : n === 0 ? "" : decode(bytes.subarray(-n)));
				else await put(ctx, decode(bytes.subarray(0, n)));
				return;
			}
			const n = count(lineSpec, 10);
			const all = text.split("\n");
			const trailing = all[all.length - 1] === "";
			if (trailing) all.pop();
			let start;
			let end;
			if (tail) {
				start = lineSpec?.startsWith("+") ? Math.max(0, n - 1) : Math.max(0, all.length - Math.abs(n));
				end = all.length;
			} else {
				start = 0;
				end = n < 0 ? Math.max(0, all.length + n) : Math.min(all.length, n);
			}
			if (end <= start) return;
			await put(ctx, all.slice(start, end).join("\n") + (end < all.length || trailing ? "\n" : ""));
		};
		const size = byteSpec !== void 0 && !tail && !byteSpec.startsWith("-") ? Math.max(0, count(byteSpec, 0)) : void 0;
		let status = 0;
		for (const operand of parsed.operands.length ? parsed.operands : ["-"]) {
			if (size !== void 0 && device(ctx.resolve(operand), 0) !== void 0) {
				header(operand);
				for (let remaining = size; remaining > 0; remaining -= 1 << 20) await put(ctx, device(ctx.resolve(operand), Math.min(remaining, 1 << 20)));
				continue;
			}
			if (operand !== "-" && operand !== "/dev/stdin" && operand !== "/dev/fd/0") {
				status |= await eachInput(ctx, [operand], async (text, name) => {
					header(name);
					await render(text);
				}, size);
				continue;
			}
			header(operand);
			const n = count(byteSpec ?? lineSpec, 10);
			if (!tail && byteSpec !== void 0 && !byteSpec.startsWith("-")) {
				for (let remaining = n; remaining > 0;) {
					const want = Math.min(remaining, 1 << 20);
					const text = await ctx.stdin.readChars(want);
					const bytes = encode(text);
					await put(ctx, bytes.length > remaining ? decode(bytes.subarray(0, remaining)) : text);
					remaining -= bytes.length;
					if (text.length < want) break;
				}
				ctx.stdin.close();
			} else if (!tail && byteSpec === void 0 && !lineSpec?.startsWith("-")) {
				let out = "";
				for (let i = 0; i < n; i++) {
					const line = await ctx.stdin.readLine();
					if (!line) break;
					out += line.text + (line.complete ? "\n" : "");
					if (out.length > 65536) {
						await put(ctx, out);
						out = "";
					}
				}
				await put(ctx, out);
				ctx.stdin.close();
			} else if (tail && byteSpec === void 0 && !lineSpec?.startsWith("+")) {
				let text = "";
				for (let chunk = await ctx.stdin.chunk(); chunk !== null; chunk = await ctx.stdin.chunk()) {
					text += chunk;
					if (text.length > 1 << 22) text = lastLines(text, Math.abs(n));
				}
				await render(lastLines(text, Math.abs(n)));
			} else await render(await ctx.stdin.text());
		}
		return status;
	}
	streaming(async (ctx) => {
		const parsed = options(ctx.args, {
			flags: "lwcmL",
			long: {
				lines: "l",
				words: "w",
				bytes: "c",
				chars: "m",
				"max-line-length": "L"
			}
		});
		const f = parsed.flags;
		const fields = f.size ? [
			"l",
			"w",
			"m",
			"c",
			"L"
		].filter((flag) => f.has(flag)) : [
			"l",
			"w",
			"c"
		];
		const rows = [];
		const totals = fields.map(() => 0);
		const tally = (text) => {
			let bytes = 0;
			return {
				counts: fields.map((field) => {
					if (field === "l") {
						let n = 0;
						for (let i = text.indexOf("\n"); i >= 0; i = text.indexOf("\n", i + 1)) n++;
						return n;
					}
					if (field === "w") return (text.match(/\S+/g) ?? []).length;
					if (field === "m") {
						let n = text.length;
						for (let i = 0; i < text.length; i++) {
							const code = text.charCodeAt(i);
							if (code >= 55296 && code <= 56319 && i + 1 < text.length) {
								const next = text.charCodeAt(i + 1);
								if (next >= 56320 && next <= 57343) {
									n--;
									i++;
								}
							}
						}
						return n;
					}
					if (field === "c") return bytes = byteLength(text);
					let max = 0;
					for (const line of text.split("\n")) max = Math.max(max, line.length);
					return max;
				}),
				bytes: fields.includes("c") ? bytes : byteLength(text)
			};
		};
		let status = 0;
		for (const operand of parsed.operands.length ? parsed.operands : ["-"]) {
			const row = {
				counts: fields.map(() => 0),
				name: parsed.operands.length ? operand : "",
				bytes: 0
			};
			const failed = await eachBatch(ctx, [operand], (text) => {
				const { counts, bytes } = tally(text);
				row.counts = row.counts.map((value, index) => fields[index] === "L" ? Math.max(value, counts[index]) : value + counts[index]);
				row.bytes += bytes;
			});
			if (failed) {
				status = failed;
				continue;
			}
			row.counts.forEach((value, index) => totals[index] = fields[index] === "L" ? Math.max(totals[index], value) : totals[index] + value);
			rows.push(row);
		}
		if (parsed.operands.length > 1) rows.push({
			counts: totals,
			name: "total",
			bytes: 0
		});
		const stdin = !parsed.operands.length || parsed.operands.includes("-");
		const bytes = rows.slice(0, parsed.operands.length || 1).reduce((sum, row) => sum + row.bytes, 0);
		const width = fields.length === 1 && rows.length === 1 ? 0 : Math.max(stdin ? 7 : 1, String(bytes).length);
		for (const row of rows) ctx.stdout.write(row.counts.map((value) => String(value).padStart(width)).join(" ") + (row.name ? " " + row.name : "") + "\n");
		return status;
	});
	function scan(text, options) {
		const all = text.split(options.separator ?? "\n");
		if (all[all.length - 1] === "") all.pop();
		const regex = options.regex;
		const context = !options.silent && !options.only && (options.before > 0 || options.after > 0);
		const starts = [];
		if (options.offsets) {
			let offset = 0;
			for (const line of all) {
				starts.push(offset);
				offset += encode(line).length + 1;
			}
		}
		const prefix = (n, mark, column) => (options.name !== void 0 ? options.name + mark : "") + (options.numbers ? n + 1 + (options.base ?? 0) + mark : "") + (options.offsets ? (starts[n] ?? 0) + (column !== void 0 && !options.column ? encode(all[n].slice(0, column)).length : 0) + mark : "") + (options.column && column !== void 0 ? column + 1 + mark : "");
		const replaced = (line) => options.replace === void 0 ? line : line.replace(regex, options.replace);
		let matches = 0;
		let lastPrinted = -1;
		let pendingAfter = 0;
		const emit = (i, mark, body) => {
			if (context && options.state.printed && lastPrinted !== i - 1) options.write("--" + options.terminator);
			options.state.printed = true;
			lastPrinted = i;
			options.write(prefix(i, mark) + body + options.terminator);
		};
		for (let i = 0; i < all.length; i++) {
			const line = all[i];
			if (matches >= options.max) {
				if (!context || pendingAfter <= 0) break;
				emit(i, "-", line);
				pendingAfter--;
				continue;
			}
			regex.lastIndex = 0;
			if (!(regex.test(line) !== options.invert)) {
				if (context && pendingAfter > 0) {
					emit(i, "-", line);
					pendingAfter--;
				}
				continue;
			}
			matches++;
			if (options.silent) continue;
			if (context) for (let j = Math.max(lastPrinted + 1, i - options.before); j < i; j++) emit(j, "-", all[j]);
			if (options.only && !options.invert) {
				regex.lastIndex = 0;
				for (const match of line.matchAll(regex)) {
					if (!match[0]) continue;
					options.state.printed = true;
					options.write(prefix(i, ":", match.index) + (options.replace === void 0 ? match[0] : match[0].replace(new RegExp(regex.source, regex.flags.replace("g", "")), options.replace)) + options.terminator);
				}
			} else if (options.column) {
				regex.lastIndex = 0;
				const first = options.invert ? null : regex.exec(line);
				options.state.printed = true;
				options.write(prefix(i, ":", first?.index ?? 0) + replaced(line) + options.terminator);
			} else emit(i, ":", replaced(line));
			pendingAfter = options.after;
		}
		return matches;
	}
	function perlSource(pattern) {
		let source = pattern;
		let flags = "";
		const inline = source.match(/^\(\?([imsx]+)\)/);
		if (inline) {
			source = source.slice(inline[0].length);
			flags = inline[1].replace(/x/g, "");
		}
		source = source.replace(/\(\?P</g, "(?<").replace(/\\A/g, "^").replace(/\\[zZ]/g, "$");
		return {
			source,
			flags
		};
	}
	streaming(async (ctx) => {
		const parsed = options(ctx.args, {
			flags: "ivncLlrRhHqsoxwEFGPZaIUzb",
			values: "eABCmfd",
			numeric: true,
			long: {
				"ignore-case": "i",
				"invert-match": "v",
				"line-number": "n",
				count: "c",
				"files-with-matches": "l",
				"files-without-match": "L",
				recursive: "r",
				"dereference-recursive": "R",
				"no-filename": "h",
				"with-filename": "H",
				quiet: "q",
				silent: "q",
				"no-messages": "s",
				"only-matching": "o",
				"line-regexp": "x",
				"word-regexp": "w",
				"extended-regexp": "E",
				"fixed-strings": "F",
				"basic-regexp": "G",
				"perl-regexp": "P",
				regexp: "e",
				"after-context": "A",
				"before-context": "B",
				context: "C",
				"max-count": "m",
				file: "f",
				include: "include",
				exclude: "exclude",
				"exclude-dir": "exclude-dir",
				color: "",
				colour: "",
				"null-data": "z",
				null: "Z",
				binary: "",
				text: "a",
				"line-buffered": "",
				"no-ignore-case": "",
				"byte-offset": "b",
				label: "label",
				"binary-files": "binary-files",
				directories: "d",
				devices: "devices"
			}
		});
		const f = parsed.flags;
		const operands = [...parsed.operands];
		const patterns = [...parsed.values.get("e") ?? []];
		for (const file of parsed.values.get("f") ?? []) try {
			for (const line of lines(file === "-" ? await ctx.stdin.text() : decode(await ctx.fs.read(ctx.resolve(file))))) patterns.push(line);
		} catch (error) {
			if (!(error instanceof FsError)) throw error;
			throw new CommandError(file + ": No such file or directory", 2);
		}
		if (!parsed.values.has("e") && !parsed.values.has("f")) {
			if (!operands.length) throw new CommandError("usage: grep [OPTION]... PATTERNS [FILE]...", 2);
			for (const line of operands.shift().split("\n")) patterns.push(line);
		}
		let flags = (f.has("i") ? "i" : "") + "g";
		const sources = patterns.map((pattern) => {
			let source;
			if (f.has("F")) source = escapeRegExp(pattern);
			else if (f.has("P")) {
				const perl = perlSource(pattern);
				source = perl.source;
				if (perl.flags.includes("i") && !flags.includes("i")) flags += "i";
				if (perl.flags.includes("s") && !flags.includes("s")) flags += "s";
			} else try {
				source = posixRegExp(pattern, f.has("E"), "").source;
			} catch (error) {
				throw new CommandError(error.message.replace(/^Invalid regular expression: /, ""), 2);
			}
			if (f.has("w")) source = "(?<![\\w])(?:" + source + ")(?![\\w])";
			if (f.has("x")) source = "^(?:" + source + ")$";
			return source;
		});
		let regex;
		try {
			regex = new RegExp(sources.length ? sources.map((source) => "(?:" + source + ")").join("|") : "(?!)", flags);
		} catch (error) {
			throw new CommandError("invalid regular expression: " + error.message, 2);
		}
		const recursive = f.has("r") || f.has("R") || last(parsed, "d") === "recurse";
		const implicit = !operands.length && recursive;
		const include = (parsed.values.get("include") ?? []).map((glob) => globRegExp(glob));
		const exclude = (parsed.values.get("exclude") ?? []).map((glob) => globRegExp(glob));
		const excludeDir = (parsed.values.get("exclude-dir") ?? []).map((glob) => globRegExp(glob));
		const targets = [];
		let status = 1;
		let errors = false;
		let directories = false;
		const prunable = !f.has("v") && !f.has("L") && !f.has("c") ? literals(patterns, f.has("F") ? "fixed" : f.has("P") ? "perl" : f.has("E") ? "extended" : "basic") : null;
		const exactTerms = (f.has("l") || f.has("q")) && !f.has("v") && !f.has("L") && !f.has("c") && !f.has("w") && !f.has("x") && !f.has("z") ? exactLiterals(patterns, f.has("F") ? "fixed" : f.has("P") ? "perl" : f.has("E") ? "extended" : "basic") : null;
		const collect = async (operand, display, top, tree) => {
			const path = ctx.resolve(operand);
			const stat = tree && !top ? prunedStat(tree, path) : await ctx.fs.stat(path);
			if (!stat && device(path) !== void 0) {
				targets.push({
					path,
					display
				});
				return;
			}
			if (!stat) {
				if (!f.has("s")) ctx.stderr.write("grep: " + display + ": No such file or directory\n");
				errors = true;
				return;
			}
			const name = path.slice(path.lastIndexOf("/") + 1);
			if (stat.kind === "directory") {
				if (!recursive) {
					if (last(parsed, "d") === "skip") return;
					if (!f.has("s")) ctx.stderr.write("grep: " + display + ": Is a directory\n");
					errors = true;
					return;
				}
				directories = true;
				if (!top && excludeDir.some((glob) => glob.test(name))) return;
				if (top) tree = await pruned(ctx.fs, path, prunable, exactTerms && {
					literals: exactTerms,
					ignoreCase: f.has("i")
				});
				for (const child of tree ? prunedList(tree, path) : await ctx.fs.list(path)) await collect((path === "/" ? "" : path) + "/" + child, display === "" ? child : display.replace(/\/$/, "") + "/" + child, false, tree);
				return;
			}
			if (!top || recursive) {
				if (include.length && !include.some((glob) => glob.test(name))) return;
				if (exclude.some((glob) => glob.test(name))) return;
			}
			targets.push({
				path,
				display,
				pruned: !!tree && !top || top && !!prunable,
				matched: !!tree?.exact && !top
			});
		};
		if (implicit) await collect(".", "", true);
		else for (const operand of operands) if (operand === "-") targets.push("-");
		else await collect(operand, operand, true);
		const named = f.has("H") || !f.has("h") && (operands.length > 1 || directories);
		const context = Number(last(parsed, "n") ?? 0);
		const after = Number(last(parsed, "A") ?? last(parsed, "C") ?? context);
		const before = Number(last(parsed, "B") ?? last(parsed, "C") ?? context);
		const max = last(parsed, "m") === void 0 ? Infinity : Number(last(parsed, "m"));
		const terminator = f.has("z") ? "\0" : "\n";
		const nameEnd = f.has("Z") ? "\0" : ":";
		const state = { printed: false };
		const listing = f.has("q") || f.has("l") || f.has("L") || f.has("c");
		const separator = f.has("z") ? "\0" : "\n";
		const search = async (source, name, stream) => {
			let matches = 0;
			let binary = false;
			let base = 0;
			for (let text = await source(); text !== null; text = await source()) {
				binary ||= !f.has("a") && !f.has("z") && text.includes("\0");
				const silent = listing || binary || last(parsed, "binary-files") === "without-match";
				let output = "";
				matches += scan(text, {
					regex,
					invert: f.has("v"),
					max: max - matches,
					before,
					after,
					only: f.has("o"),
					numbers: f.has("n"),
					offsets: f.has("b"),
					name: named ? name + (f.has("Z") ? "\0" : "") : void 0,
					base,
					separator,
					terminator,
					silent,
					state,
					write: (chunk) => void (output += chunk)
				});
				if (f.has("Z") && named) output = output.replace(/\0[:-]/g, "\0");
				await put(ctx, output);
				if (!stream) continue;
				if (f.has("n")) for (let i = text.indexOf(separator); i >= 0; i = text.indexOf(separator, i + 1)) base++;
				if (f.has("q") && matches || matches >= max) {
					ctx.stdin.close();
					break;
				}
			}
			if (binary && matches && !listing && last(parsed, "binary-files") !== "without-match") ctx.stderr.write("grep: " + name + ": binary file matches\n");
			if (f.has("q")) return matches > 0;
			if (f.has("c")) ctx.stdout.write((named ? name + nameEnd : "") + matches + "\n");
			if (f.has("l") && matches) ctx.stdout.write(name + (f.has("Z") ? "\0" : "\n"));
			if (f.has("L") && !matches) ctx.stdout.write(name + (f.has("Z") ? "\0" : "\n"));
			return matches > 0;
		};
		const once = (text) => {
			let done = false;
			return async () => {
				if (done) return null;
				done = true;
				return text;
			};
		};
		const stdin = () => {
			if (!before && !after && !f.has("b")) return [batches(ctx.stdin, separator), true];
			let done = false;
			return [async () => {
				if (done) return null;
				done = true;
				return ctx.stdin.text();
			}, false];
		};
		const stdinName = last(parsed, "label") ?? "(standard input)";
		if (!operands.length && !recursive) {
			const [source, stream] = stdin();
			if (await search(source, stdinName, stream)) status = 0;
		} else {
			let stdinUsed = false;
			const partial = prunable && !f.has("b") && !before && !after && !f.has("z") ? prunable : null;
			const take = ahead(targets, (target) => target === "-" || target.matched || device(target.path) !== void 0 ? null : partial && target.pruned ? ctx.fs.excerpt?.(target.path, partial).then((bytes) => bytes ?? ctx.fs.read(target.path)) ?? ctx.fs.read(target.path) : ctx.fs.read(target.path));
			for (let index = 0; index < targets.length; index++) {
				const target = targets[index];
				const pending = take(index);
				if (ctx.stdout.closed) throw new PipeError();
				if (target !== "-" && target.matched) {
					status = 0;
					if (f.has("q")) return 0;
					ctx.stdout.write(target.display + (f.has("Z") ? "\0" : "\n"));
					continue;
				}
				let source;
				let stream = false;
				let display;
				if (target === "-") {
					if (stdinUsed) continue;
					stdinUsed = true;
					[source, stream] = stdin();
					display = stdinName;
				} else {
					display = target.display;
					try {
						source = once(device(target.path) ?? decode(await pending));
					} catch (error) {
						if (!(error instanceof FsError)) throw error;
						errors = true;
						continue;
					}
				}
				if (await search(source, display, stream)) {
					status = 0;
					if (f.has("q")) return 0;
				}
			}
		}
		return errors && !(f.has("q") && status === 0) ? 2 : status;
	});
	streaming(async (ctx) => {
		const parsed = options(ctx.args, {
			flags: "cdui",
			values: "fsw",
			long: {
				count: "c",
				repeated: "d",
				unique: "u",
				"ignore-case": "i",
				"skip-fields": "f",
				"skip-chars": "s",
				"check-chars": "w"
			}
		});
		const f = parsed.flags;
		const skipFields = Number(last(parsed, "f") ?? 0);
		const skipChars = Number(last(parsed, "s") ?? 0);
		const width = last(parsed, "w") === void 0 ? void 0 : Number(last(parsed, "w"));
		const key = (line) => {
			let value = line;
			for (let i = 0; i < skipFields; i++) value = value.replace(/^\s*\S+/, "");
			value = value.slice(skipChars);
			if (width !== void 0) value = value.slice(0, width);
			return f.has("i") ? value.toLowerCase() : value;
		};
		let current;
		let out = "";
		const target = parsed.operands[1];
		const flush = (group) => {
			if (f.has("d") && group.count < 2 || f.has("u") && group.count !== 1) return;
			out += (f.has("c") ? String(group.count).padStart(7) + " " : "") + group.line + "\n";
		};
		const status = await eachBatch(ctx, parsed.operands.slice(0, 1), async (text) => {
			for (const line of lines(text)) {
				const value = key(line);
				if (current && current.key === value) current.count++;
				else {
					if (current) flush(current);
					current = {
						line,
						key: value,
						count: 1
					};
				}
			}
			if (target === void 0 && out.length > 65536) {
				await put(ctx, out);
				out = "";
			}
		});
		if (current) flush(current);
		if (target !== void 0) await ctx.fs.write(ctx.resolve(target), encode(out));
		else await put(ctx, out);
		return status;
	});
	function ranges(spec) {
		const parts = spec.split(",").map((part) => {
			const match = part.match(/^(\d*)(-?)(\d*)$/);
			if (!match || !match[1] && !match[3]) throw new CommandError("invalid field range", 1);
			const from = match[1] ? Number(match[1]) : 1;
			return [from, match[2] ? match[3] ? Number(match[3]) : Infinity : from];
		});
		return (n) => parts.some(([from, to]) => n >= from && n <= to);
	}
	function merged(spec) {
		const parts = spec.split(",").map((part) => {
			const match = part.match(/^(\d*)(-?)(\d*)$/);
			const from = match[1] ? Number(match[1]) : 1;
			return [from, match[2] ? match[3] ? Number(match[3]) : Infinity : from];
		}).sort((a, b) => a[0] - b[0]);
		const spans = [];
		for (const part of parts) {
			const previous = spans[spans.length - 1];
			if (previous && part[0] <= previous[1] + 1) previous[1] = Math.max(previous[1], part[1]);
			else spans.push(part);
		}
		return spans;
	}
	streaming(async (ctx) => {
		const parsed = options(ctx.args, {
			flags: "sn",
			values: "dfcb",
			long: {
				delimiter: "d",
				fields: "f",
				characters: "c",
				bytes: "b",
				"only-delimited": "s",
				complement: "C",
				"output-delimiter": "output-delimiter",
				"zero-terminated": "z"
			}
		});
		const fields = last(parsed, "f");
		const chars = last(parsed, "c") ?? last(parsed, "b");
		if ((parsed.values.get("f")?.length ?? 0) + (parsed.values.get("c")?.length ?? 0) + (parsed.values.get("b")?.length ?? 0) > 1) throw new CommandError("only one list may be specified");
		if (!fields && !chars) throw new CommandError("you must specify a list of bytes, characters, or fields");
		const complement = parsed.flags.has("C");
		const selector = ranges(fields ?? chars);
		const pick = (n) => selector(n) !== complement;
		const delimiter = last(parsed, "d") ?? "	";
		if (delimiter.length !== 1) throw new CommandError("the delimiter must be a single character");
		const output = last(parsed, "output-delimiter") ?? (fields ? delimiter : "");
		const spans = !fields && !complement && output === "" ? merged(fields ?? chars) : void 0;
		return await eachBatch(ctx, parsed.operands, (text) => {
			const out = [];
			for (const line of lines(text)) if (fields) {
				if (!line.includes(delimiter)) {
					if (!parsed.flags.has("s")) out.push(line);
					continue;
				}
				out.push(line.split(delimiter).filter((_, index) => pick(index + 1)).join(output));
			} else if (spans && !/[\uD800-\uDFFF]/.test(line)) {
				let picked = "";
				for (const [from, to] of spans) picked += line.slice(from - 1, to);
				out.push(picked);
			} else out.push([...line].filter((_, index) => pick(index + 1)).join(output));
			return put(ctx, joinLines(out));
		});
	});
	const CLASS_CHARS = {
		lower: "abcdefghijklmnopqrstuvwxyz",
		upper: "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
		digit: "0123456789",
		space: " 	\n\r\f\v",
		blank: " 	",
		punct: "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~",
		xdigit: "0123456789ABCDEFabcdef"
	};
	CLASS_CHARS.alpha = CLASS_CHARS.lower + CLASS_CHARS.upper;
	CLASS_CHARS.alnum = CLASS_CHARS.alpha + CLASS_CHARS.digit;
	function trSet(spec) {
		const out = [];
		const [text] = escapes(spec);
		for (let i = 0; i < text.length; i++) {
			const cls = text.slice(i).match(/^\[:(\w+):\]/);
			if (cls && CLASS_CHARS[cls[1]]) {
				out.push(...CLASS_CHARS[cls[1]]);
				i += cls[0].length - 1;
				continue;
			}
			const repeat = text.slice(i).match(/^\[(.)\*(\d*)\]/);
			if (repeat) {
				out.push(...Array(Number(repeat[2] || 0) || 1).fill(repeat[1]));
				i += repeat[0].length - 1;
				continue;
			}
			if (text[i + 1] === "-" && i + 2 < text.length) {
				const from = text.charCodeAt(i);
				const to = text.charCodeAt(i + 2);
				for (let c = from; c <= to; c++) out.push(String.fromCharCode(c));
				i += 2;
				continue;
			}
			out.push(text[i]);
		}
		return out;
	}
	streaming(async (ctx) => {
		const parsed = options(ctx.args, {
			flags: "dscCt",
			long: {
				delete: "d",
				"squeeze-repeats": "s",
				complement: "c",
				truncate: "t"
			}
		});
		const f = parsed.flags;
		const [first, second] = parsed.operands;
		if (first === void 0) throw new CommandError("missing operand");
		const complement = f.has("c") || f.has("C");
		const set2 = second !== void 0 ? trSet(second) : [];
		const list1 = f.has("t") && second !== void 0 ? trSet(first).slice(0, set2.length) : trSet(first);
		const set1 = new Set(list1);
		const inSet1 = (c) => set1.has(c) !== complement;
		let previous = "";
		let last = -1;
		let map;
		let squeezable;
		const squeeze = f.has("s") ? new Set(f.has("d") || second === void 0 ? second === void 0 ? [...set1] : set2 : set2) : void 0;
		const translate = (c) => {
			if (f.has("d")) return inSet1(c) ? void 0 : c;
			if (second === void 0 || !inSet1(c)) return c;
			if (complement) return set2[set2.length - 1] ?? c;
			const index = list1.lastIndexOf(c);
			return index < set2.length ? set2[index] : set2[set2.length - 1] ?? c;
		};
		const squeezes = (value) => squeeze !== void 0 && (second === void 0 && !f.has("d") ? inSet1(value) : squeeze.has(value));
		const simple = [...list1, ...set2].every((c) => c.length === 1 && !/[\uD800-\uDFFF]/.test(c));
		const convert = (input) => {
			if (simple && (!complement || !/[\uD800-\uDFFF]/.test(input))) {
				if (!map || !squeezable) {
					map = /* @__PURE__ */ new Int32Array(65536);
					squeezable = /* @__PURE__ */ new Uint8Array(65536);
					for (let code = 0; code < 65536; code++) {
						const value = translate(String.fromCharCode(code));
						map[code] = value === void 0 ? -1 : value.charCodeAt(0);
						if (value !== void 0 && squeezes(value)) squeezable[map[code]] = 1;
					}
				}
				const codes = new Uint16Array(input.length);
				let n = 0;
				for (let i = 0; i < input.length; i++) {
					const value = map[input.charCodeAt(i)];
					if (value < 0 || value === last && squeezable[value]) continue;
					codes[n++] = value;
					last = value;
				}
				previous = last < 0 ? previous : String.fromCharCode(last);
				const chunks = [];
				for (let i = 0; i < n; i += 8192) chunks.push(String.fromCharCode.apply(null, codes.subarray(i, Math.min(n, i + 8192))));
				return chunks.join("");
			}
			let out = "";
			for (const c of input) {
				let value = c;
				if (f.has("d")) {
					if (inSet1(c)) continue;
				} else if (second !== void 0 && inSet1(c)) {
					if (complement) value = set2[set2.length - 1] ?? c;
					else {
						const index = list1.lastIndexOf(c);
						value = index < set2.length ? set2[index] : set2[set2.length - 1] ?? c;
					}
				}
				if (squeeze && value === previous && (second === void 0 && !f.has("d") ? inSet1(value) : squeeze.has(value))) continue;
				out += value;
				previous = value;
			}
			last = previous.length === 1 ? previous.charCodeAt(0) : -1;
			return out;
		};
		for (let chunk = await ctx.stdin.chunk(); chunk !== null; chunk = await ctx.stdin.chunk()) {
			const code = chunk.charCodeAt(chunk.length - 1);
			if (code >= 55296 && code <= 56319) {
				const next = await ctx.stdin.readChars(1);
				chunk += next;
			}
			await put(ctx, convert(chunk));
		}
		return 0;
	});
	streaming(async (ctx) => await eachLine(ctx, ctx.args, (line) => /[\uD800-\uDFFF]/.test(line) ? [...line].reverse().join("") : line.split("").reverse().join("")));
	streaming(async (ctx) => {
		const parsed = options(ctx.args, {
			values: "bwsvinh",
			long: {
				"body-numbering": "b",
				"number-width": "w",
				"number-separator": "s",
				"starting-line-number": "v",
				"line-increment": "i",
				"number-format": "n",
				"header-numbering": "h"
			}
		});
		const style = last(parsed, "b") ?? "t";
		const width = Number(last(parsed, "w") ?? 6);
		const separator = last(parsed, "s") ?? "	";
		const increment = Number(last(parsed, "i") ?? 1);
		const formatting = last(parsed, "n") ?? "rn";
		if (![
			"ln",
			"rn",
			"rz"
		].includes(formatting)) throw new CommandError("invalid line numbering format: '" + formatting + "'");
		const pattern = style.startsWith("p") ? posixRegExp(style.slice(1), false) : void 0;
		let n = Number(last(parsed, "v") ?? 1);
		const number = (value) => {
			const digits = String(value);
			if (formatting === "ln") return digits.padEnd(width);
			if (formatting === "rz") return value < 0 ? "-" + String(-value).padStart(width - 1, "0") : digits.padStart(width, "0");
			return digits.padStart(width);
		};
		return eachLine(ctx, parsed.operands, (line) => {
			if (!(style === "a" || style === "t" && line !== "" || pattern !== void 0 && pattern.test(line))) return " ".repeat(width + separator.length) + line;
			const result = number(n) + separator + line;
			n += increment;
			return result;
		}, true);
	});
	streaming(async (ctx) => {
		const args = ctx.args;
		let i = 0;
		let max;
		let maxLines;
		let replace;
		let delimiter;
		let skipEmpty = false;
		let trace = false;
		let file;
		let eof;
		const value = (arg, short, long) => {
			if (arg === short || arg === long) return args[++i];
			if (arg.startsWith(long + "=")) return arg.slice(long.length + 1);
			if (arg.startsWith(short) && short.length === 2 && !arg.startsWith("--")) return arg.slice(2);
		};
		for (; i < args.length && args[i].startsWith("-") && args[i] !== "-"; i++) {
			const arg = args[i];
			if (arg === "--") {
				i++;
				break;
			}
			let v;
			if (arg === "-0" || arg === "--null") delimiter = "\0";
			else if (arg === "-r" || arg === "--no-run-if-empty") skipEmpty = true;
			else if (arg === "-t" || arg === "--verbose") trace = true;
			else if (arg === "-x" || arg === "--exit" || arg === "-p" || arg === "--interactive" || arg === "--open-tty" || arg === "-o") continue;
			else if (arg === "-i" || arg === "--replace") replace = "{}";
			else if (arg.startsWith("-i") || arg.startsWith("--replace=")) replace = arg.startsWith("-i") ? arg.slice(2) : arg.slice(10);
			else if ((v = value(arg, "-I", "-I")) !== void 0) replace = v;
			else if ((v = value(arg, "-n", "--max-args")) !== void 0) max = Number(v);
			else if ((v = value(arg, "-L", "--max-lines")) !== void 0) maxLines = Number(v);
			else if (arg === "-l") maxLines = 1;
			else if ((v = value(arg, "-d", "--delimiter")) !== void 0) delimiter = escapes(v)[0];
			else if ((v = value(arg, "-a", "--arg-file")) !== void 0) file = v;
			else if ((v = value(arg, "-E", "--eof")) !== void 0) eof = v;
			else if (arg.startsWith("-e")) eof = arg.slice(2) || void 0;
			else if (value(arg, "-P", "--max-procs") !== void 0 || value(arg, "-s", "--max-chars") !== void 0 || value(arg, "-S", "--process-slot-var") !== void 0) continue;
			else throw new CommandError("invalid option -- '" + arg.slice(1) + "'", 1);
			if (max !== void 0 && (!Number.isInteger(max) || max < 1)) throw new CommandError("value " + max + " for -n option should be >= 1", 1);
		}
		const command = args.slice(i).length ? args.slice(i) : ["echo"];
		let next;
		if (file !== void 0) {
			let input;
			try {
				input = await readInput(ctx, file);
			} catch {
				throw new CommandError("Cannot open input file '" + file + "': No such file or directory", 1);
			}
			next = async () => {
				const text = input;
				input = null;
				return text;
			};
		} else next = batches(ctx.stdin, delimiter ?? "\n");
		const unquote = (text) => {
			const out = [];
			for (const match of text.matchAll(/(?:"([^"]*)"|'([^']*)'|\\([\s\S])|([^\s"'\\]+))+|\s+/g)) {
				if (/^\s+$/.test(match[0])) continue;
				out.push(match[0].replace(/"([^"]*)"|'([^']*)'|\\([\s\S])/g, (_, a, b, c) => a ?? b ?? c ?? ""));
			}
			return out;
		};
		let status = 0;
		let ran = 0;
		let stopped = false;
		const execute = async (group) => {
			ran++;
			const argv = replace !== void 0 ? command.map((word) => word.split(replace).join(group[0] ?? "")) : [...command, ...group];
			if (trace) ctx.stderr.write(argv.join(" ") + "\n");
			let code;
			try {
				code = await ctx.run(argv, "");
			} catch (error) {
				if (!(error instanceof PipeError)) throw error;
				code = 141;
			}
			if (code === 141) {
				ctx.stderr.write("xargs: " + argv[0] + ": terminated by signal 13\n");
				return 125;
			}
			if (code === 255) {
				ctx.stderr.write("xargs: " + argv[0] + ": exited with status 255; aborting\n");
				return 124;
			}
			if (code === 127 || code === 126) return code;
			if (code !== 0) status = 123;
		};
		const base = command.reduce((sum, word) => sum + word.length + 1, 0);
		let pending = [];
		let length = base;
		let current = [];
		let count = 0;
		let text = await next();
		while (text !== null && !stopped) {
			const following = await next();
			const final = following === null;
			const groups = [];
			if (replace !== void 0) {
				const items = delimiter !== void 0 ? text.split(delimiter) : text.split("\n").map((line) => line.replace(/^[ \t]+/, ""));
				if (items[items.length - 1] === "") items.pop();
				for (const item of items) {
					if (delimiter === void 0 && item === "") continue;
					if (eof !== void 0 && item === eof) {
						stopped = true;
						break;
					}
					groups.push([item]);
				}
			} else if (maxLines !== void 0 && delimiter === void 0) {
				const parts = text.split("\n");
				if (parts[parts.length - 1] === "" && parts.length > 1) parts.pop();
				for (const line of parts) {
					const words = unquote(line);
					if (eof !== void 0 && words[0] === eof) {
						stopped = true;
						break;
					}
					if (!words.length) continue;
					for (const word of words) current.push(word);
					if (/[ \t]$/.test(line)) continue;
					if (++count >= maxLines) {
						groups.push(current);
						current = [];
						count = 0;
					}
				}
			} else {
				let items;
				if (delimiter !== void 0) {
					items = text.split(delimiter);
					if (items[items.length - 1] === "" || final && delimiter !== "\n" && items[items.length - 1] === "\n" && delimiter !== "\0") items.pop();
				} else items = unquote(text);
				if (eof !== void 0 && delimiter === void 0) {
					const stop = items.indexOf(eof);
					if (stop >= 0) {
						items = items.slice(0, stop);
						stopped = true;
					}
				}
				const size = max ?? maxLines;
				for (const item of items) {
					if (size === void 0 && pending.length && length + item.length + 1 > 131072) {
						groups.push(pending);
						pending = [];
						length = base;
					}
					pending.push(item);
					length += item.length + 1;
					if (size !== void 0 && pending.length >= Math.max(1, size)) {
						groups.push(pending);
						pending = [];
					}
				}
			}
			for (const group of groups) {
				const code = await execute(group);
				if (code !== void 0) return code;
			}
			text = following;
		}
		const rest = current.length ? current : pending;
		if (rest.length) {
			const code = await execute(rest);
			if (code !== void 0) return code;
		}
		if (!ran) {
			if (skipEmpty || replace !== void 0) return 0;
			const code = await execute([]);
			if (code !== void 0) return code;
		}
		return status;
	});
	function digest(algorithm) {
		return checksum(async (bytes) => [...new Uint8Array(await crypto.subtle.digest(algorithm, bytes))].map((byte) => byte.toString(16).padStart(2, "0")).join(""), algorithm.replace("-", ""));
	}
	function checksum(hash, tag) {
		return async (ctx) => {
			const parsed = options(ctx.args, {
				flags: "bctwz",
				long: {
					binary: "b",
					check: "c",
					text: "t",
					tag: "T",
					warn: "w",
					quiet: "q",
					status: "s",
					strict: "S",
					"ignore-missing": "i",
					zero: "z"
				}
			});
			const f = parsed.flags;
			const read = async (operand) => operand === "-" ? encode(ctx.stdin.read()) : await ctx.fs.read(ctx.resolve(operand));
			let status = 0;
			if (!f.has("c")) {
				for (const operand of parsed.operands.length ? parsed.operands : ["-"]) {
					let bytes;
					try {
						bytes = await read(operand);
					} catch (error) {
						ctx.stderr.write(ctx.name + ": " + operand + ": " + (error instanceof FsError && error.code === "EISDIR" ? "Is a directory" : "No such file or directory") + "\n");
						status = 1;
						continue;
					}
					const value = await hash(bytes);
					ctx.stdout.write((f.has("T") ? tag + " (" + operand + ") = " + value : value + (f.has("b") ? " *" : "  ") + operand) + (f.has("z") ? "\0" : "\n"));
				}
				return status;
			}
			let failed = 0;
			let unreadable = 0;
			let malformed = 0;
			for (const operand of parsed.operands.length ? parsed.operands : ["-"]) {
				let text;
				try {
					text = await readInput(ctx, operand);
				} catch {
					ctx.stderr.write(ctx.name + ": " + operand + ": No such file or directory\n");
					status = 1;
					continue;
				}
				let valid = 0;
				for (const line of lines(text)) {
					const match = line.match(/^\\?([0-9a-fA-F]+) [ *](.+)$/) ?? line.match(/^\w+ \((.+)\) = ([0-9a-fA-F]+)$/);
					if (!match) {
						if (line.trim() !== "" && !line.startsWith("#")) malformed++;
						continue;
					}
					valid++;
					const [expected, name] = line.startsWith(tag + " (") || /^\w+ \(/.test(line) ? [match[2], match[1]] : [match[1], match[2]];
					let bytes;
					try {
						bytes = await read(name);
					} catch {
						if (f.has("i")) continue;
						ctx.stderr.write(ctx.name + ": " + name + ": No such file or directory\n");
						if (!f.has("s")) ctx.stdout.write(name + ": FAILED open or read\n");
						unreadable++;
						continue;
					}
					const ok = await hash(bytes) === expected.toLowerCase();
					if (!ok) failed++;
					if (!f.has("s") && (!ok || !f.has("q"))) ctx.stdout.write(name + ": " + (ok ? "OK" : "FAILED") + "\n");
				}
				if (!valid) {
					ctx.stderr.write(ctx.name + ": " + (operand === "-" ? "standard input" : operand) + ": no properly formatted checksum lines found\n");
					status = 1;
				}
			}
			if (!f.has("s")) {
				if (malformed && f.has("w")) ctx.stderr.write(ctx.name + ": WARNING: " + malformed + " line" + (malformed === 1 ? " is" : "s are") + " improperly formatted\n");
				if (unreadable) ctx.stderr.write(ctx.name + ": WARNING: " + unreadable + " listed file" + (unreadable === 1 ? "" : "s") + " could not be read\n");
				if (failed) ctx.stderr.write(ctx.name + ": WARNING: " + failed + " computed checksum" + (failed === 1 ? "" : "s") + " did NOT match\n");
			}
			return failed || unreadable || malformed && f.has("S") ? 1 : status;
		};
	}
	streaming((ctx) => headTail(ctx, false)), streaming((ctx) => headTail(ctx, true)), digest("SHA-256"), digest("SHA-1"), digest("SHA-512");
	// src/bash/internal/commands/files.ts
	function failure(error) {
		if (error instanceof FsError) return {
			ENOENT: "No such file or directory",
			EEXIST: "File exists",
			ENOTDIR: "Not a directory",
			EISDIR: "Is a directory",
			ENOTEMPTY: "Directory not empty",
			EFBIG: "File too large"
		}[error.code] ?? error.message;
		return error instanceof Error ? error.message : String(error);
	}
	function visible(text, tabs) {
		let out = "";
		for (const value of encode(text)) {
			let byte = value;
			let prefix = "";
			if (byte >= 128) {
				prefix = "M-";
				byte -= 128;
			}
			if (byte === 9 && !tabs && !prefix) out += "	";
			else if (byte === 10 && !prefix) out += "\n";
			else if (byte < 32) out += prefix + "^" + String.fromCharCode(byte + 64);
			else if (byte === 127) out += prefix + "^?";
			else out += prefix + String.fromCharCode(byte);
		}
		return out;
	}
	streaming(async (ctx) => {
		const parsed = options(ctx.args, {
			flags: "nbsAEvTetu",
			long: {
				number: "n",
				"number-nonblank": "b",
				"squeeze-blank": "s",
				"show-ends": "E",
				"show-all": "A",
				"show-tabs": "T",
				"show-nonprinting": "v"
			}
		});
		const f = parsed.flags;
		const nonprinting = f.has("A") || f.has("v") || f.has("e") || f.has("t");
		const tabs = f.has("A") || f.has("T") || f.has("t");
		const ends = f.has("A") || f.has("E") || f.has("e");
		const plain = !f.has("n") && !f.has("b") && !ends && !f.has("s") && !nonprinting && !tabs;
		let line = 0;
		let blank = false;
		const render = (text) => {
			if (nonprinting) text = visible(text, tabs);
			else if (tabs) text = text.replace(/\t/g, "^I");
			const parts = text.split("\n");
			const trailing = parts[parts.length - 1] === "";
			if (trailing) parts.pop();
			const out = [];
			for (const part of parts) {
				if (parsed.flags.has("s") && part === "" && blank) continue;
				blank = part === "";
				const numbered = parsed.flags.has("b") ? part !== "" : parsed.flags.has("n");
				out.push((numbered ? String(++line).padStart(6) + "	" : "") + part + (ends ? "$" : ""));
			}
			return out.join("\n") + (trailing ? "\n" : "");
		};
		let status = 0;
		for (const operand of parsed.operands.length ? parsed.operands : ["-"]) {
			blank = false;
			if (plain && (operand === "-" || operand === "/dev/stdin" || operand === "/dev/fd/0")) {
				for (let chunk = await ctx.stdin.chunk(); chunk !== null; chunk = await ctx.stdin.chunk()) await put(ctx, chunk);
				continue;
			}
			status |= await eachBatch(ctx, [operand], (text) => put(ctx, plain ? text : render(text)));
		}
		return status;
	});
	streaming(async (ctx) => {
		const parsed = options(ctx.args, {
			flags: "ai",
			long: { append: "a" }
		});
		const failed = /* @__PURE__ */ new Set();
		let status = 0;
		let first = true;
		const store = async (text) => {
			for (const operand of parsed.operands) {
				if (failed.has(operand)) continue;
				try {
					await ctx.fs.write(ctx.resolve(operand), encode(text), !first || parsed.flags.has("a"));
				} catch (error) {
					ctx.stderr.write("tee: " + operand + ": " + failure(error) + "\n");
					failed.add(operand);
					status = 1;
				}
			}
			first = false;
		};
		for (let chunk = await ctx.stdin.chunk(); chunk !== null; chunk = await ctx.stdin.chunk()) {
			await store(chunk);
			await put(ctx, chunk);
		}
		if (first) await store("");
		return status;
	});
	String.raw`
const { parentPort, workerData } = require("node:worker_threads");
const { createRequire } = require("node:module");
const RESERVED = ["/dev", "/proc", "/lib", "/home/pyodide", "/home/web_user"];
const reserved = path => RESERVED.some(prefix => path === prefix || path.startsWith(prefix + "/"));
const join = (base, name) => base === "/" ? "/" + name : base + "/" + name;
const within = (path, dir) => path === dir || path.startsWith(dir === "/" ? "/" : dir + "/");
const parentOf = path => { const i = path.lastIndexOf("/"); return i <= 0 ? "/" : path.slice(0, i); };
const decoder = new TextDecoder();
let py, start, cancel, loading, micropip = false, mirrored = [], mirror = null, known = new Map(), tracking = null;
const WRITES = 1 | 2 | 64 | 512 | 1024;
function absolute(path) {
  if (path.startsWith("/")) return path;
  const cwd = py.FS.cwd();
  return (cwd === "/" ? "" : cwd) + "/" + path;
}
function track(fs) {
  const delegate = fs.trackingDelegate;
  delegate.onOpenFile = (path, flags) => { if (tracking && (flags & WRITES)) tracking.dirty.add(absolute(path)); };
  delegate.onWriteToFile = path => { if (tracking) tracking.dirty.add(absolute(path)); };
  delegate.onMovePath = (from, to) => { if (tracking) { tracking.gone.add(absolute(from)); tracking.dirty.add(absolute(to)); } };
  delegate.onDeletePath = path => { if (tracking) tracking.gone.add(absolute(path)); };
  delegate.onMakeDirectory = path => { if (tracking) tracking.dirty.add(absolute(path)); };
  const truncate = fs.truncate.bind(fs);
  fs.truncate = (path, length) => { if (tracking && typeof path === "string") tracking.dirty.add(absolute(path)); return truncate(path, length); };
}
function changes(fs, roots) {
  const files = new Map(), dirs = new Set(), deleted = new Set();
  const inside = path => !reserved(path) && roots.some(root => within(path, root));
  const visit = path => {
    if (!inside(path)) return;
    if (!fs.analyzePath(path).exists) return void deleted.add(path);
    const mode = fs.stat(path).mode;
    if (fs.isFile(mode)) return void files.set(path, fs.readFile(path));
    if (!fs.isDir(mode) || dirs.has(path)) return;
    dirs.add(path);
    for (const name of fs.readdir(path)) if (name !== "." && name !== "..") visit(join(path, name));
  };
  for (const path of [...tracking.gone, ...tracking.dirty]) visit(path);
  return { files, dirs: [...dirs], deleted: [...deleted] };
}
async function load() {
  let mod;
  for (const from of [process.cwd() + "/package.json", workerData.from]) {
    try { mod = createRequire(from)("pyodide"); break; } catch {}
  }
  if (!mod) mod = await import("pyodide");
  py = await mod.loadPyodide({ packageCacheDir: workerData.cacheDir, stdout: () => {}, stderr: () => {} });
  track(py.FS);
  const ns = py.globals.get("dict")();
  py.runPython(workerData.helper, { globals: ns });
  start = ns.get("start");
  cancel = ns.get("cancel");
}
function unmirror(fs, path) {
  if (reserved(path) || !fs.analyzePath(path).exists) return;
  if (!fs.isDir(fs.stat(path).mode)) return fs.unlink(path);
  for (const name of fs.readdir(path)) if (name !== "." && name !== "..") unmirror(fs, join(path, name));
  if (path !== "/" && !RESERVED.some(prefix => within(prefix, path))) fs.rmdir(path);
}
function prune(fs, path, dirs, listing) {
  if (reserved(path) || !fs.analyzePath(path).exists) return;
  if (!fs.isDir(fs.stat(path).mode)) {
    if (!listing.has(path)) unmirror(fs, path);
    return;
  }
  if (!dirs.has(path) && !mirrored.includes(path)) return unmirror(fs, path);
  for (const name of fs.readdir(path)) if (name !== "." && name !== "..") prune(fs, join(path, name), dirs, listing);
}
function sync(message) {
  const fs = py.FS;
  fs.chdir("/");
  if (message.mirror !== mirror) {
    for (const path of mirrored) unmirror(fs, path);
    mirrored = [];
    known.clear();
    mirror = message.mirror;
  }
  const listing = new Map(message.files);
  const dirs = new Set(message.dirs);
  for (const path of [...known.keys()]) {
    if (listing.has(path)) continue;
    unmirror(fs, path);
    known.delete(path);
  }
  for (const root of message.roots) if (!mirrored.includes(root)) mirrored.push(root);
  for (const root of mirrored) prune(fs, root, dirs, listing);
  for (const dir of [...dirs].sort()) fs.mkdirTree(dir);
  return [...listing].filter(([path, stamp]) => known.get(path) !== stamp).map(([path]) => path);
}
async function run(id, job) {
  const fs = py.FS;
  const out = (fd, text) => parentPort.postMessage({ id, type: "out", fd, text });
  for (const [path, data, stamp] of job.files) {
    fs.mkdirTree(parentOf(path));
    fs.writeFile(path, data);
    known.set(path, stamp);
  }
  fs.mkdirTree(job.cwd);
  const messages = { messageCallback: () => {}, errorCallback: message => out(2, message + "\n") };
  try {
    if (job.kind === "pip" && !micropip) { await py.loadPackage("micropip", messages); micropip = true; }
    if (job.kind === "module") await py.loadPackagesFromImports("import " + job.target, messages);
    else if (job.kind !== "pip") await py.loadPackagesFromImports(job.target, messages);
  } catch (error) {
    out(2, job.name + ": " + (error && error.message || String(error)) + "\n");
  }
  let offset = 0;
  py.setStdin({ isatty: false, read(buffer) { const count = Math.min(buffer.length, job.stdin.length - offset); buffer.set(job.stdin.subarray(offset, offset + count)); offset += count; return count; } });
  const sink = fd => ({ isatty: false, write(buffer) { out(fd, decoder.decode(buffer)); return buffer.length; } });
  py.setStdout(sink(1));
  py.setStderr(sink(2));
  py.setInterruptBuffer(new Int32Array(job.interrupt));
  let status;
  tracking = { dirty: new Set(), gone: new Set() };
  try {
    status = Number(await start(JSON.stringify({ kind: job.kind, target: job.target, argv: job.argv, filename: job.filename, cwd: job.cwd, env: job.env, path0: job.path0 })));
  } finally {
    py.setInterruptBuffer(undefined);
  }
  const found = changes(fs, job.roots);
  tracking = null;
  for (const path of [...found.files.keys(), ...found.deleted]) known.delete(path);
  parentPort.postMessage({ id, type: "done", status, files: found.files, dirs: found.dirs, deleted: found.deleted });
}
parentPort.on("message", async message => {
  if (message.type === "cancel") { try { cancel && cancel(); } catch {} return; }
  try {
    await (loading ??= load());
    if (message.type === "version") return parentPort.postMessage({ id: message.id, type: "done", version: String(py.runPython("import sys; sys.version.split()[0]")) });
    if (message.type === "preload") { await py.loadPackage(message.packages, { messageCallback: () => {}, errorCallback: () => {} }); return parentPort.postMessage({ id: message.id, type: "done" }); }
    if (message.type === "sync") return parentPort.postMessage({ id: message.id, type: "done", need: sync(message.sync) });
    if (message.type === "stamps") { for (const [path, stamp] of message.stamps) known.set(path, stamp); return parentPort.postMessage({ id: message.id, type: "done" }); }
    await run(message.id, message.job);
  } catch (error) {
    parentPort.postMessage({ id: message.id, type: "error", message: error && error.stack || String(error) });
  }
});
`;
	Promise.resolve();
	// src/bash/internal/commands/python.ts
	const pyodideVersion = "314.0.7";
	const pyodideUrl = "https://cdn.jsdelivr.net/pyodide/v314.0.7/full/";
	exports.HELPER = String.raw`
import asyncio, json, os, signal, sys, traceback, types
from pyodide.code import eval_code_async
import warnings
warnings.filterwarnings("ignore", message="The [xy] parameter as float was deprecated")
sys.dont_write_bytecode = True
_base = set(sys.modules)
_active = False

class Interrupted(Exception):
    pass


def _status(error):
    code = error.code
    if code is None:
        return 0
    if isinstance(code, bool) or not isinstance(code, int):
        print(code, file=sys.stderr)
        return 1
    return code & 255

def _internal(code):
    name = code.co_filename
    return name in ("<exec>", "<nanocode>") or name.startswith("/lib/python") and ("/_pyodide/" in name or "/pyodide/" in name or name.endswith("/runpy.py"))

def _interrupt(signum, frame):
    while _active and frame is not None:
        if "/asyncio/" in frame.f_code.co_filename or frame.f_code.co_filename.endswith("/webloop.py"):
            return
        if not _internal(frame.f_code):
            raise Interrupted()
        frame = frame.f_back

signal.signal(signal.SIGINT, _interrupt)

_NETWORK = ("socket", "ssl", "http.client", "urllib.error", "urllib3", "requests", "httpx", "aiohttp")

def _offline(error):
    seen = set()
    while error is not None and id(error) not in seen:
        seen.add(id(error))
        kind = type(error)
        if isinstance(error, (ConnectionError, TimeoutError)) or kind.__module__.split(".")[0] in _NETWORK or kind.__module__ in _NETWORK or "TLS not supported" in str(error):
            return True
        tb = error.__traceback__
        while isinstance(error, OSError) and tb is not None:
            if tb.tb_frame.f_code.co_filename.endswith(("/socket.py", "/ssl.py", "/http/client.py", "/urllib/request.py")):
                return True
            tb = tb.tb_next
        error = error.__cause__ or error.__context__
    return False

def _report(error):
    tb = error.__traceback__
    while tb is not None and _internal(tb.tb_frame.f_code):
        tb = tb.tb_next
    traceback.print_exception(type(error), error, tb)
    if _offline(error):
        print("python3: Python here runs on Pyodide (WebAssembly) and cannot open network connections. Download the file with curl in bash first (curl -sL -o data.json URL), then read it from Python.", file=sys.stderr)

def _streams():
    sys.stdin = open("/dev/stdin", "r", encoding="utf-8", errors="surrogateescape")
    sys.stdout = open("/dev/stdout", "w", encoding="utf-8", errors="backslashreplace", buffering=1)
    sys.stderr = open("/dev/stderr", "w", encoding="utf-8", errors="backslashreplace", buffering=1)

async def _pip(args):
    import micropip
    if not args or args[0] in ("-h", "--help", "help"):
        print("usage: pip install [-r FILE] [--no-deps] [--pre] [-i URL] PKG... | uninstall PKG... | list | freeze | show PKG")
        return 0
    if args[0] in ("-V", "--version"):
        print("pip (micropip " + getattr(micropip, "__version__", "") + " on Pyodide)")
        return 0
    command, rest = args[0], args[1:]
    if command == "install":
        reqs, deps, pre, index, quiet, i = [], True, False, None, False, 0
        while i < len(rest):
            arg = rest[i]
            if arg in ("-r", "--requirement") or arg.startswith("--requirement="):
                if "=" in arg:
                    path = arg.split("=", 1)[1]
                else:
                    i += 1
                    path = rest[i]
                for line in open(path).read().splitlines():
                    line = line.split("#", 1)[0].strip()
                    if line and not line.startswith("-"):
                        reqs.append(line)
            elif arg in ("-i", "--index-url"):
                i += 1
                index = rest[i]
            elif arg.startswith("--index-url="):
                index = arg.split("=", 1)[1]
            elif arg == "--no-deps":
                deps = False
            elif arg == "--pre":
                pre = True
            elif arg in ("-q", "--quiet", "-qq", "-qqq"):
                quiet = True
            elif not arg.startswith("-"):
                reqs.append("emfs:" + os.path.abspath(arg) if arg.endswith(".whl") and os.path.exists(arg) else arg)
            i += 1
        if not reqs:
            print("ERROR: You must give at least one requirement to install", file=sys.stderr)
            return 1
        before = {name: package.version for name, package in micropip.list().items()}
        try:
            await micropip.install(reqs, deps=deps, pre=pre, index_urls=index)
        except Exception as error:
            print("ERROR: " + str(error), file=sys.stderr)
            return 1
        added = sorted(name + "-" + package.version for name, package in micropip.list().items() if before.get(name) != package.version)
        if not quiet:
            print("Successfully installed " + " ".join(added) if added else "Requirement already satisfied: " + " ".join(reqs))
        return 0
    if command == "uninstall":
        installed = micropip.list()
        for name in [arg for arg in rest if not arg.startswith("-")]:
            if name not in installed:
                print("WARNING: Skipping " + name + " as it is not installed.", file=sys.stderr)
                continue
            micropip.uninstall(name)
            print("Successfully uninstalled " + name + "-" + installed[name].version)
        return 0
    if command in ("list", "freeze"):
        packages = sorted(micropip.list().items(), key=lambda item: item[0].lower())
        if command == "freeze":
            for name, package in packages:
                print(name + "==" + package.version)
            return 0
        width = max([len("Package")] + [len(name) for name, _ in packages])
        print("Package".ljust(width) + " Version")
        print("-" * width + " -------")
        for name, package in packages:
            print(name.ljust(width) + " " + package.version)
        return 0
    if command == "show":
        from importlib import metadata
        status = 0
        for name in [arg for arg in rest if not arg.startswith("-")]:
            try:
                meta = metadata.metadata(name)
            except metadata.PackageNotFoundError:
                print("WARNING: Package(s) not found: " + name, file=sys.stderr)
                status = 1
                continue
            for key in ("Name", "Version", "Summary", "Home-page", "Author", "License"):
                print(key + ": " + (meta.get(key) or ""))
            print("Requires: " + ", ".join(metadata.requires(name) or []))
        return status
    print("ERROR: unknown command " + repr(command) + " (supported: install, uninstall, list, freeze, show)", file=sys.stderr)
    return 1

_task = None

def start(request):
    global _task
    _task = asyncio.ensure_future(run(request))
    return _task

def cancel():
    if _task is not None and not _task.done():
        _task.cancel()

async def run(request):
    global _active
    request = json.loads(request)
    kind, target, filename = request["kind"], request["target"], request["filename"]
    os.chdir(request["cwd"])
    os.environ.clear()
    os.environ.update(request["env"])
    sys.argv = request["argv"]
    sys.path[0] = request["path0"]
    _streams()
    previous = sys.modules.get("__main__")
    main = types.ModuleType("__main__")
    main.__dict__["__builtins__"] = __builtins__
    if kind == "file":
        main.__file__ = filename
    status = 0
    try:
        _active = True
        if kind == "pip":
            status = await _pip(request["argv"])
        elif kind == "module":
            import runpy
            runpy.run_module(target, run_name="__main__", alter_sys=True)
        else:
            sys.modules["__main__"] = main
            await eval_code_async(target, main.__dict__, return_mode="none", filename=filename, dedent=False)
    except (Interrupted, asyncio.CancelledError):
        status = -1
    except SystemExit as error:
        status = _status(error)
    except KeyboardInterrupt:
        print("KeyboardInterrupt", file=sys.stderr)
        status = 130
    except BaseException as error:
        _report(error)
        status = 1
    finally:
        _active = False
        for stream in (sys.stdout, sys.stderr, sys.stdin):
            try:
                stream.close()
            except Exception:
                pass
        if previous is not None:
            sys.modules["__main__"] = previous
        for name, module in list(sys.modules.items()):
            path = getattr(module, "__file__", None)
            if name not in _base and name != "__main__" and isinstance(path, str) and not path.startswith("/lib/"):
                del sys.modules[name]
    return status
`;
	exports.pyodideUrl = pyodideUrl;
	exports.pyodideVersion = pyodideVersion;
	return exports;
})({});
