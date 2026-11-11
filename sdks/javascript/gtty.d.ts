// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// Types for gtty.js: what every update may hold (docs/protocol.md). A key
// left out stays as it is; null clears it.

export type Color = number | string; // 0xrrggbb or "#rrggbb"
export interface TextPart { string: string; fg?: Color; bk?: Color; size?: number; bold?: boolean; stroke?: boolean }
/** A string, or at most 8 parts. */
export type Text = string | TextPart[];

export interface Item { id?: string; text?: Text; data?: string }
/** No onclick (and no dots): only an icon. */
export interface Button { id?: string; icon?: string; text?: Text; onclick?: string; data?: string; dots?: "vertical" | "horizontal"; items?: Item[] }
export interface Line { id?: string; prefixButton?: Button | null; text?: Text; postButton?: Button | null; onclick?: string; onhover?: string; data?: string }
export interface Chip { text?: Text | null; dimmed?: boolean | null; onclick?: string | null; onhover?: string | null; data?: string | null }
export interface Peek extends Line { expand?: boolean | null; hoverExpand?: boolean | null; onexpand?: string | null }
export interface Filter { text?: string; hint?: Text; options?: string[]; onclick: string }
/** left and right: 2 buttons each at most. */
export interface Frame { left?: Button[]; right?: Button[]; text?: Text; onclick?: string; onhover?: string; data?: string; filter?: Filter | null }
export interface Epeek {
  frame?: Frame | null; lines?: Line[] | null; selected?: number | null; empty?: Text | null; footer?: Text | null;
  state?: "idle" | "busy" | "ok" | "err" | null; message?: Text[] | null;
}
export interface Widget { id: string; type?: "text" | "checkbox" | "dropdown" | "label"; label?: Text; value?: string | boolean; options?: string[]; filter?: boolean }
export interface Dialog {
  title?: Text; layout?: "form" | "grid" | "table"; columns?: number; rows?: number; fields?: Widget[];
  buttons?: "ok" | "okcancel" | "yesno"; onclick?: string; timeout?: number; error?: string | null;
}
export type Update = { chip: Chip } | { peek: Peek | null } | { epeek: Epeek | null } | { dialog: Dialog };

export type ErrorName = "WindowClosed" | "NoChip" | "BadName" | "NoFile" | "FileInUse" | "FileClosed" | "StorageFull" | "StorageFailed";
export class GttyError extends Error { name: ErrorName }

export class ButtonClick {
  id: string; text: string; data: string; function: string; command: boolean;
  fields: { id: string; value: string | boolean }[];
  field(id: string): string | null;
  checked(id: string): boolean;
}
export class Event {
  eventId: number; kind: "window_changed" | "command_started" | "key" | "button_click";
  folder: string; branch: string; remote: boolean; command: string;
  /** key: its name, what it typed, the modifier keys (cmd: ⌘ / Super) */
  key: string; text: string; ctrl: boolean; shift: boolean; alt: boolean; cmd: boolean;
  button: ButtonClick | null;
}

export class File {
  read(size?: number): Promise<Buffer>;
  readAll(): Promise<Buffer>;
  write(data: Buffer | string): Promise<void>;
  close(): Promise<void>;
}
export class Storage {
  openWrite(name: string, timeoutMs?: number): Promise<File>;
  openRead(name: string, timeoutMs?: number): Promise<File>;
  delete(name: string, timeoutMs?: number): Promise<void>;
  list(): Promise<string[]>;
}
export type Level = "debug" | "info" | "warn" | "err";
export class Window {
  id: number;
  ui: {
    set(update: Update): void;
    setDisplayMode(mode: "chip" | "peek" | "epeek"): void;
    showDialog(): void;
    closeDialog(): void;
  };
  events: { register(kind: "window_changed" | "command_started" | "key"): void; unregister(kind: "window_changed" | "command_started" | "key"): void };
  ephemeral: Storage;
  stateful: Storage;
  shell(): Promise<string>;
  log(level: Level, message: string): void;
}
export class Extension { name: string; log(level: Level, message: string): void }

export interface Definition {
  onGttyStart?(ext: Extension): void | Promise<void>;
  onWindowStart?(win: Window): void | Promise<void>;
  onWindowClose?(win: Window): void | Promise<void>;
  onGttyClose?(ext: Extension): void | Promise<void>;
  onEvent?(win: Window, ev: Event): void | Promise<void>;
}
export function run(ext: Definition): Promise<void>;
export function dispatch(actions: Record<string, (win: Window, b: ButtonClick) => unknown>, win: Window, ev: Event): unknown;
export function newText(string: string, attr?: Omit<TextPart, "string">): Text;
export function newText(...parts: [string, Omit<TextPart, "string">?][]): Text;
export const API_VERSION: 1;
