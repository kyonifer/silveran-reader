import { debugLog } from "./DebugConfig.js";

const ICON = {
  more:
    '<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="12" r="1.7"/><circle cx="12" cy="12" r="1.7"/><circle cx="19" cy="12" r="1.7"/></svg>',
  dictionary:
    '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"/></svg>',
  copy:
    '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>',
  trash:
    '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>',
  edit:
    '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg>',
};

/**
 * SelectionToolbar - compact floating icon bar anchored to a selection or
 * tapped highlight.
 *
 * Rendered into the top-level (untransformed) document at a `fixed` position;
 * the caller supplies a rect already in top-document viewport coordinates, plus
 * the button actions. This class only builds and places the DOM.
 */
export class SelectionToolbar {
  #palette = [];
  #el = null;
  #doc = null;

  setPalette(palette) {
    this.#palette = Array.isArray(palette) ? palette : [];
  }

  get isVisible() {
    return this.#el != null;
  }

  hide() {
    if (this.#el && this.#el.parentNode) {
      this.#el.parentNode.removeChild(this.#el);
    }
    this.#el = null;
    this.#doc = null;
  }

  showForSelection(topDoc, rect, actions) {
    const el = this.#begin(topDoc);

    el.appendChild(this.#swatchGroup((id) => actions.highlight(id)));
    el.appendChild(
      this.#iconButton(ICON.more, "More", () => {
        actions.note();
        this.hide();
      })
    );
    el.appendChild(this.#divider());
    el.appendChild(
      this.#iconButton(ICON.dictionary, "Define", () => {
        actions.define();
        this.hide();
      })
    );
    el.appendChild(
      this.#iconButton(ICON.copy, "Copy", () => {
        actions.copy();
        this.hide();
      })
    );

    this.#finish(rect);
  }

  showForHighlight(topDoc, rect, currentColor, actions) {
    const el = this.#begin(topDoc);

    el.appendChild(
      this.#swatchGroup((id) => actions.setColor(id), currentColor)
    );
    el.appendChild(this.#divider());
    el.appendChild(
      this.#iconButton(ICON.trash, "Delete", () => {
        actions.delete();
        this.hide();
      })
    );
    el.appendChild(
      this.#iconButton(ICON.edit, "Edit", () => {
        actions.edit();
        this.hide();
      })
    );

    this.#finish(rect);
  }

  #begin(topDoc) {
    this.hide();
    this.#doc = topDoc;

    const el = topDoc.createElement("div");
    el.className = "silveran-selection-toolbar";
    el.style.cssText = [
      "position:fixed",
      "z-index:2147483647",
      "display:flex",
      "align-items:center",
      "gap:2px",
      "padding:4px 7px",
      "border-radius:11px",
      "background:rgba(38,38,40,0.98)",
      "box-shadow:0 2px 14px rgba(0,0,0,0.4)",
      "user-select:none",
      "-webkit-user-select:none",
      "opacity:0",
      "transition:opacity 0.1s ease",
    ].join(";");

    // Keep the selection alive (mousedown would otherwise collapse it) and stop
    // taps from reaching the reader's page-turn / overlay-toggle click handler.
    const swallow = (e) => {
      e.preventDefault();
      e.stopPropagation();
    };
    el.addEventListener("mousedown", swallow, true);
    el.addEventListener("pointerdown", swallow, true);
    el.addEventListener("touchstart", (e) => e.stopPropagation(), { passive: true });
    el.addEventListener("click", (e) => e.stopPropagation());

    this.#el = el;
    return el;
  }

  #finish(rect) {
    const doc = this.#doc;
    (doc.body || doc.documentElement).appendChild(this.#el);
    this.#position(rect);
    debugLog("SelectionToolbar", "shown");
  }

  #swatchGroup(onPick, currentColor) {
    const group = this.#doc.createElement("div");
    group.style.cssText = "display:flex;align-items:center;gap:7px;padding:0 4px;";
    for (const entry of this.#palette) {
      const selected =
        currentColor != null &&
        (entry.color === currentColor || entry.id === currentColor);
      group.appendChild(this.#swatch(entry, selected, () => onPick(entry.id)));
    }
    return group;
  }

  #iconButton(svg, title, onClick) {
    const b = this.#doc.createElement("button");
    b.type = "button";
    b.title = title;
    b.innerHTML = svg;
    b.style.cssText = [
      "all:unset",
      "cursor:pointer",
      "width:30px",
      "height:30px",
      "display:flex",
      "align-items:center",
      "justify-content:center",
      "border-radius:7px",
      "color:#fff",
    ].join(";");
    b.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      onClick();
    });
    return b;
  }

  #swatch(entry, selected, onClick) {
    const b = this.#doc.createElement("button");
    b.type = "button";
    b.title = entry.label || entry.id;
    b.style.cssText = [
      "all:unset",
      "cursor:pointer",
      "width:21px",
      "height:21px",
      "border-radius:50%",
      `background:${entry.color}`,
      selected
        ? "box-shadow:0 0 0 2px #fff"
        : "box-shadow:0 0 0 1px rgba(255,255,255,0.3)",
    ].join(";");
    b.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      onClick();
    });
    return b;
  }

  #divider() {
    const d = this.#doc.createElement("div");
    d.style.cssText =
      "width:1px;height:22px;background:rgba(255,255,255,0.18);margin:0 4px;flex:none;";
    return d;
  }

  #position(rect) {
    const el = this.#el;
    const view = this.#doc?.defaultView;
    if (!el || !view) return;

    const vw = view.innerWidth;
    const vh = view.innerHeight;
    const w = el.offsetWidth;
    const h = el.offsetHeight;

    let left = rect.left + rect.width / 2 - w / 2;
    left = Math.max(8, Math.min(left, vw - w - 8));

    let top = rect.top - h - 10;
    if (top < 8) top = rect.bottom + 10;
    top = Math.max(8, Math.min(top, vh - h - 8));

    el.style.left = `${Math.round(left)}px`;
    el.style.top = `${Math.round(top)}px`;
    view.requestAnimationFrame(() => {
      el.style.opacity = "1";
    });
  }
}

export default SelectionToolbar;
