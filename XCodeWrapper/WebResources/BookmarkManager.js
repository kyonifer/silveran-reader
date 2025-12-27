import { Overlayer } from "./foliate-js/overlayer.js";
import { debugLog } from "./DebugConfig.js";

console.log("[BookmarkManager] Module loaded");

class BookmarkManager {
  #view = null;
  #userHighlights = new Map();
  #overlayers = new Map();

  setView(view) {
    this.#view = view;
  }

  #isTouchDevice() {
    return navigator.userAgent.includes("iPhone") ||
           navigator.userAgent.includes("iPad") ||
           (navigator.userAgent.includes("Macintosh") && navigator.maxTouchPoints > 1);
  }

  setupSection(sectionIndex, doc) {
    debugLog("BookmarkManager", "setupSection called for index:", sectionIndex);

    const existingOverlayer = this.#overlayers.get(sectionIndex);
    if (existingOverlayer) {
      if (doc.contains(existingOverlayer.element)) {
        return;
      }
      this.#overlayers.delete(sectionIndex);
    }

    const overlayer = new Overlayer();
    const container = doc.body || doc.documentElement;
    overlayer.element.style.overflow = 'visible';
    overlayer.element.style.zIndex = '9999';
    overlayer.element.style.setProperty('--overlayer-highlight-opacity', '0.9');
    overlayer.element.style.setProperty('--overlayer-highlight-blend-mode', 'screen');
    container.appendChild(overlayer.element);
    this.#overlayers.set(sectionIndex, overlayer);

    this.#renderHighlightsForSection(sectionIndex, doc);

    doc.addEventListener("click", (event) => {
      const result = overlayer.hitTest({ x: event.clientX, y: event.clientY });
      if (result && result.length > 0) {
        const highlightId = result[0];
        debugLog("BookmarkManager", "Highlight tapped:", highlightId);
        window.webkit?.messageHandlers?.HighlightTapped?.postMessage({
          highlightId: highlightId,
        });
        event.stopPropagation();
      }
    });

    if (!this.#isTouchDevice()) {
      debugLog("BookmarkManager", "Setting up contextmenu listener for desktop");
      doc.addEventListener("contextmenu", (event) =>
        this.#handleContextMenu(event, sectionIndex, doc)
      );
    }
    debugLog("BookmarkManager", "setupSection complete for index:", sectionIndex);
  }

  #handleContextMenu(event, sectionIndex, doc) {
    debugLog("BookmarkManager", "contextmenu event fired");

    const selection = doc.getSelection?.();
    debugLog("BookmarkManager", "selection:", selection ? `"${selection.toString()}"` : "null", "isCollapsed:", selection?.isCollapsed);

    if (!selection || selection.isCollapsed) {
      debugLog("BookmarkManager", "No selection, ignoring contextmenu");
      return;
    }

    const text = selection.toString().trim();
    if (!text || text.length < 2) {
      debugLog("BookmarkManager", "Text too short, ignoring");
      return;
    }

    const range = selection.getRangeAt(0);
    if (!range) return;

    let cfi = null;
    try {
      cfi = this.#view.getCFI(sectionIndex, range);
    } catch (error) {
      debugLog("BookmarkManager", "Failed to get CFI from selection:", error);
      return;
    }

    if (!cfi) return;

    const href = this.#view?.book?.sections?.[sectionIndex]?.id || "";
    const title =
      this.#view?.book?.toc?.find((t) => t.href?.startsWith(href))?.label ||
      null;

    const startContainer = range.startContainer;
    const endContainer = range.endContainer;

    const startCssSelector = this.#getCssSelector(
      startContainer.parentElement || startContainer
    );
    const endCssSelector = this.#getCssSelector(
      endContainer.parentElement || endContainer
    );

    const startTextNodeIndex = this.#getTextNodeIndex(startContainer);
    const endTextNodeIndex = this.#getTextNodeIndex(endContainer);

    const payload = {
      sectionIndex,
      cfi,
      text,
      href,
      title,
      startCssSelector,
      startTextNodeIndex,
      startCharOffset: range.startOffset,
      endCssSelector,
      endTextNodeIndex,
      endCharOffset: range.endOffset,
    };

    debugLog(
      "BookmarkManager",
      "Context menu with selection:",
      text.substring(0, 50) + "..."
    );
    window.webkit?.messageHandlers?.TextSelection?.postMessage(payload);

    event.preventDefault();
  }

  #getCssSelector(element) {
    if (!element || element.nodeType !== Node.ELEMENT_NODE) return "";

    if (element.id) return `#${element.id}`;

    const parts = [];
    let current = element;

    while (current && current.nodeType === Node.ELEMENT_NODE) {
      let selector = current.tagName.toLowerCase();

      if (current.id) {
        selector = `#${current.id}`;
        parts.unshift(selector);
        break;
      }

      if (current.parentElement) {
        const siblings = Array.from(current.parentElement.children);
        const sameTagSiblings = siblings.filter(
          (s) => s.tagName === current.tagName
        );
        if (sameTagSiblings.length > 1) {
          const index = sameTagSiblings.indexOf(current) + 1;
          selector += `:nth-of-type(${index})`;
        }
      }

      parts.unshift(selector);
      current = current.parentElement;
    }

    return parts.join(" > ");
  }

  #getTextNodeIndex(node) {
    if (node.nodeType !== Node.TEXT_NODE) return 0;

    const parent = node.parentElement;
    if (!parent) return 0;

    let index = 0;
    for (const child of parent.childNodes) {
      if (child === node) return index;
      if (child.nodeType === Node.TEXT_NODE) index++;
    }

    return 0;
  }

  #renderHighlightsForSection(sectionIndex, doc) {
    const overlayer = this.#overlayers.get(sectionIndex);
    if (!overlayer) return;

    for (const [id] of this.#userHighlights) {
      overlayer.remove(id);
    }

    for (const [id, highlight] of this.#userHighlights) {
      if (highlight.sectionIndex !== sectionIndex) continue;

      try {
        const range = this.#createRangeFromCFI(highlight.cfi, sectionIndex, doc);
        if (!range) {
          debugLog("BookmarkManager", `Could not create range for highlight ${id}`);
          continue;
        }

        overlayer.add(id, range, Overlayer.highlight, {
          color: highlight.color,
        });
        debugLog("BookmarkManager", `Rendered highlight ${id} with color ${highlight.color}`);
      } catch (error) {
        debugLog("BookmarkManager", `Failed to render highlight ${id}:`, error);
      }
    }
  }

  #createRangeFromCFI(cfi, sectionIndex, doc) {
    if (!this.#view || !cfi || !doc) return null;

    try {
      const resolved = this.#view.resolveCFI?.(cfi);
      if (!resolved) {
        debugLog("BookmarkManager", "resolveCFI returned null for:", cfi);
        return null;
      }

      if (resolved.index !== sectionIndex) {
        debugLog("BookmarkManager", `CFI section mismatch: expected ${sectionIndex}, got ${resolved.index}`);
        return null;
      }

      if (typeof resolved.anchor === "function") {
        const range = resolved.anchor(doc);
        if (range) {
          debugLog("BookmarkManager", "Got range from anchor function");
          return range;
        }
      }

      if (resolved.range) {
        return resolved.range;
      }
    } catch (error) {
      debugLog("BookmarkManager", "resolveCFI failed:", error);
    }

    return null;
  }

  redrawAllOverlayers() {
    const contents = this.#view?.renderer?.getContents?.() || [];

    for (const content of contents) {
      if (!content.doc) continue;

      const existingOverlayer = this.#overlayers.get(content.index);
      const inCurrentDoc = existingOverlayer && content.doc.contains(existingOverlayer.element);

      if (!inCurrentDoc) {
        this.#overlayers.delete(content.index);
        this.setupSection(content.index, content.doc);
      } else {
        existingOverlayer.redraw();
      }
    }
  }

  renderHighlights(jsonString) {
    debugLog("BookmarkManager", "renderHighlights() called");

    let highlights;
    try {
      highlights = JSON.parse(jsonString);
    } catch (error) {
      console.error("[BookmarkManager] Failed to parse highlights JSON:", error);
      return;
    }

    this.#userHighlights.clear();

    for (const hl of highlights) {
      this.#userHighlights.set(hl.id, {
        sectionIndex: hl.sectionIndex,
        cfi: hl.cfi,
        color: hl.color,
      });
    }

    debugLog("BookmarkManager", `Loaded ${this.#userHighlights.size} highlights`);

    const contents = this.#view?.renderer?.getContents?.() || [];
    for (const content of contents) {
      if (content.doc) {
        this.#renderHighlightsForSection(content.index, content.doc);
      }
    }
  }

  clearAllHighlights() {
    debugLog("BookmarkManager", "clearAllHighlights()");

    for (const overlayer of this.#overlayers.values()) {
      for (const [id] of this.#userHighlights) {
        overlayer.remove(id);
      }
    }

    this.#userHighlights.clear();
  }

  removeHighlight(id) {
    debugLog("BookmarkManager", `removeHighlight(id: ${id})`);

    const highlight = this.#userHighlights.get(id);
    if (!highlight) return;

    this.#userHighlights.delete(id);

    const overlayer = this.#overlayers.get(highlight.sectionIndex);
    if (overlayer) {
      overlayer.remove(id);
    }
  }

  captureCurrentSelection() {
    debugLog("BookmarkManager", "captureCurrentSelection called");

    const contents = this.#view?.renderer?.getContents?.() || [];

    for (const content of contents) {
      if (!content.doc) continue;

      const selection = content.doc.getSelection?.();
      if (!selection || selection.isCollapsed) continue;

      const text = selection.toString().trim();
      if (!text || text.length < 2) continue;

      const range = selection.getRangeAt(0);
      if (!range) continue;

      const sectionIndex = content.index;
      let cfi = null;
      try {
        cfi = this.#view.getCFI(sectionIndex, range);
      } catch (error) {
        debugLog("BookmarkManager", "Failed to get CFI:", error);
        continue;
      }

      if (!cfi) continue;

      const href = this.#view?.book?.sections?.[sectionIndex]?.id || "";
      const title = this.#view?.book?.toc?.find((t) => t.href?.startsWith(href))?.label || null;

      const startContainer = range.startContainer;
      const endContainer = range.endContainer;
      const startCssSelector = this.#getCssSelector(startContainer.parentElement || startContainer);
      const endCssSelector = this.#getCssSelector(endContainer.parentElement || endContainer);
      const startTextNodeIndex = this.#getTextNodeIndex(startContainer);
      const endTextNodeIndex = this.#getTextNodeIndex(endContainer);

      const payload = {
        sectionIndex,
        cfi,
        text,
        href,
        title,
        startCssSelector,
        startTextNodeIndex,
        startCharOffset: range.startOffset,
        endCssSelector,
        endTextNodeIndex,
        endCharOffset: range.endOffset,
      };

      debugLog("BookmarkManager", "Captured selection:", text.substring(0, 50) + "...");
      window.webkit?.messageHandlers?.TextSelection?.postMessage(payload);

      selection.removeAllRanges();
      return true;
    }

    debugLog("BookmarkManager", "No valid selection found");
    return false;
  }
}

export default BookmarkManager;
