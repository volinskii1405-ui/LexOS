/* jsdom.js - the world a page's JavaScript lives in, in LexOS Web
 * (apps/js.h runs it first, then the page's scripts): window, document,
 * the nodes and elements over the browser's own tree (__lx: js.h's
 * functions - a node is a number there), events, timers and animation
 * frames, fetch and XMLHttpRequest, localStorage, URL, the observers,
 * custom elements. As much of what pages lean on as fits - not all the
 * web: no canvas drawing, no workers, no WebSockets (they fail, so a
 * page can fall back). */
(function (lx) {
'use strict';
const G = globalThis;
const N = Symbol('node');                                // a wrapper's node number
const L = Symbol('listeners');
const H = Symbol('handlers');                            // onclick = ... and the like
const nodes = [];                                        // node number -> its wrapper
const RAN = 8;                                           // (js.h's DF_RAN)
const docIds = lx.doc();                                 // [document, <html>, <head>, <body>]
let readyState = 'loading', curScript = null;

/* ================================================================
 * little helpers
 * ================================================================ */
const hide = (o, k, v) => Object.defineProperty(o, k, { value: v, writable: true, configurable: true, enumerable: false });
function props(o, map) {                                 // {name: [get, set]} -> accessors on o
    for (const k of Object.keys(map)) Object.defineProperty(o, k, { get: map[k][0], set: map[k][1], configurable: true, enumerable: true });
}
const kebab = s => s.startsWith('--') ? s : s.replace(/[A-Z]/g, c => '-' + c.toLowerCase()).replace(/^(webkit|moz|ms|o)-/, '-$1-');
const camel = s => s.replace(/^-(webkit|moz|ms|o)-/, '$1-').replace(/-([a-z])/g, (m, c) => c.toUpperCase());
const sv = v => v == null ? '' : String(v);
function report(e) {
    let m;
    try {
        m = String(e);
        if (e && e.stack) { const l = String(e.stack).trim().split('\n')[0].trim(); if (l) m += ' @ ' + l; }
    } catch (x) { m = 'error'; }
    lx.log(69, m);
}
function safe(fn, args, self) {
    try { return typeof fn === 'function' ? fn.apply(self, args || []) : (0, eval)(String(fn)); }
    catch (e) { report(e); }
}
if (typeof G.DOMException !== 'function') {
    G.DOMException = class DOMException extends Error {
        constructor(message, name) { super(message); this.name = name || 'Error'; }
    };
}
function W(id) {                                         // node number -> its wrapper
    if (!id) return null;
    let o = nodes[id];
    if (o) return o;
    const t = lx.type(id);
    let C;
    if (t === 1) {
        const tag = lx.atom(lx.tag(id));
        const ce = ceDefs.get(tag);
        if (ce) return upgrade(id, ce);
        C = TAGS[tag] || HTMLElement;
    } else C = t === 3 ? Text : t === 8 ? Comment : t === 9 ? Document : DocumentFragment;
    o = Object.create(C.prototype);
    o[N] = id;
    nodes[id] = o;
    if (C === HTMLTemplateElement && lx.first(id)) o.content;     // (what's in it: its content, not the page)
    return o;
}
const kidIds = (id, el) => lx.kids(id, el ? 1 : 0);
class NodeList extends Array {
    item(i) { return this[i] || null; }
    namedItem(n) { return this.find(e => e.id === n || (e.getAttribute && e.getAttribute('name') === n)) || null; }
    static get [Symbol.species]() { return Array; }
}
const HTMLCollection = NodeList;
function list(ids) { const l = new NodeList(); for (const id of ids) l.push(W(id)); return l; }
function toNode(n) { return n instanceof Node ? n : document.createTextNode(sv(n)); }
function nodeOf(n, what) {
    if (!(n instanceof Node)) throw new TypeError(`Failed to execute '${what}': parameter is not of type 'Node'.`);
    return n[N];
}

/* ================================================================
 * events
 * ================================================================ */
let wantMask = 0;
const wantCount = Object.create(null);
const MOVES = /^(mouse(move|over|out|enter|leave)|pointer(move|over|out|enter|leave))$/;
function noteWant(type, d) {
    const m = MOVES.test(type) ? 1 : type === 'scroll' || type === 'wheel' ? 2 : 0;
    if (!m) return;
    wantCount[type] = (wantCount[type] || 0) + d;
    let w = 0;
    for (const t in wantCount) if (wantCount[t] > 0) w |= MOVES.test(t) ? 1 : 2;
    if (w !== wantMask) { wantMask = w; lx.want(w); }
}
class EventTarget {
    addEventListener(type, fn, opt) {
        if (!fn) return;
        type = String(type);
        const capture = typeof opt === 'boolean' ? opt : !!(opt && opt.capture);
        const once = !!(opt && typeof opt === 'object' && opt.once), signal = opt && typeof opt === 'object' ? opt.signal : null;
        if (signal && signal.aborted) return;
        let m = this[L];
        if (!m) { m = new Map(); hide(this, L, m); }
        let a = m.get(type);
        if (!a) m.set(type, a = []);
        for (const l of a) if (l.fn === fn && l.capture === capture) return;
        a.push({ fn, capture, once, removed: false });
        noteWant(type, 1);
        if (signal) signal.addEventListener('abort', () => this.removeEventListener(type, fn, capture));
    }
    removeEventListener(type, fn, opt) {
        const capture = typeof opt === 'boolean' ? opt : !!(opt && opt.capture);
        const m = this[L], a = m && m.get(String(type));
        if (!a) return;
        const i = a.findIndex(l => l.fn === fn && l.capture === capture);
        if (i >= 0) { a[i].removed = true; a.splice(i, 1); noteWant(String(type), -1); }
    }
    dispatchEvent(ev) {
        if (!(ev instanceof Event)) throw new TypeError("Failed to execute 'dispatchEvent': parameter 1 is not of type 'Event'.");
        ev.isTrusted = false;
        dispatch(this, ev);
        return !ev.defaultPrevented;
    }
}
const handlerCode = new WeakMap();
function handlerOf(t, type) {
    const h = t[H] && t[H][type];
    if (h !== undefined) return h;
    let el = t;
    if (t === G && (type === 'load' || type === 'unload' || type === 'beforeunload' || type === 'hashchange' || type === 'popstate' ||
        type === 'resize' || type === 'message' || type === 'pageshow' || type === 'error')) el = document.body;
    if (!el || !(el instanceof Element)) return null;
    const code = el.getAttribute('on' + type);
    if (code === null) return null;
    let c = handlerCode.get(el);
    if (!c) handlerCode.set(el, c = {});
    if (!c[type] || c[type].src !== code) {
        let f = null;
        try { f = new Function('event', code); } catch (e) { report(e); }
        c[type] = { src: code, f };
    }
    return c[type].f;
}
function call(fn, t, ev, isHandler) {
    try {
        let r;
        if (typeof fn === 'function') r = fn.call(t, ev);
        else if (fn && typeof fn.handleEvent === 'function') r = fn.handleEvent(ev);
        if (isHandler && r === false) ev.preventDefault();
    } catch (e) { report(e); }
}
function invoke(t, ev, phase) {
    ev.currentTarget = t;
    if (phase !== 1) { const h = handlerOf(t, ev.type); if (h) call(h, t, ev, true); }
    const m = t[L], a = m && m.get(ev.type);
    if (!a || ev._stopNow) return;
    for (const l of a.slice()) {
        if (l.removed) continue;
        if (phase === 1 && !l.capture) continue;
        if (phase === 3 && l.capture) continue;
        if (l.once) t.removeEventListener(ev.type, l.fn, l.capture);
        call(l.fn, t, ev, false);
        if (ev._stopNow) break;
    }
}
function evPath(t) {
    const p = [];
    if (t instanceof Node) {
        for (let n = t; n; n = n.parentNode || (n instanceof ShadowRoot ? n.host : null)) p.push(n);
        if (p[p.length - 1] === document) p.push(G);
    } else p.push(t);
    return p;
}
function dispatch(t, ev) {
    const p = evPath(t);
    ev.target = t;
    ev._path = p;
    ev.eventPhase = 1;
    for (let i = p.length - 1; i > 0 && !ev._stop; i--) invoke(p[i], ev, 1);
    ev.eventPhase = 2;
    if (!ev._stop) invoke(t, ev, 2);
    if (ev.bubbles) { ev.eventPhase = 3; for (let i = 1; i < p.length && !ev._stop; i++) invoke(p[i], ev, 3); }
    ev.eventPhase = 0;
    ev.currentTarget = null;
    return !ev.defaultPrevented;
}
function fire(t, type, init, C) {
    const ev = new (C || Event)(type, init);
    ev.isTrusted = true;
    dispatch(t, ev);
    return ev;
}
class Event {
    constructor(type, init) {
        if (!arguments.length) throw new TypeError("Failed to construct 'Event': 1 argument required.");
        init = init || {};
        this.type = String(type);
        this.bubbles = !!init.bubbles;
        this.cancelable = !!init.cancelable;
        this.composed = !!init.composed;
        this.defaultPrevented = false;
        this.isTrusted = false;
        this.timeStamp = lx.now();
        this.eventPhase = 0;
        this.target = null;
        this.currentTarget = null;
        hide(this, '_stop', false);
        hide(this, '_stopNow', false);
        hide(this, '_path', null);
    }
    get srcElement() { return this.target; }
    get returnValue() { return !this.defaultPrevented; }
    set returnValue(v) { if (!v) this.preventDefault(); }
    get cancelBubble() { return this._stop; }
    set cancelBubble(v) { if (v) this._stop = true; }
    preventDefault() { if (this.cancelable) this.defaultPrevented = true; }
    stopPropagation() { this._stop = true; }
    stopImmediatePropagation() { this._stop = this._stopNow = true; }
    composedPath() { return this._path ? this._path.slice() : []; }
    initEvent(type, bubbles, cancelable) { this.type = String(type); this.bubbles = !!bubbles; this.cancelable = !!cancelable; }
}
Object.assign(Event, { NONE: 0, CAPTURING_PHASE: 1, AT_TARGET: 2, BUBBLING_PHASE: 3 });
class UIEvent extends Event {
    constructor(type, init) { super(type, init); init = init || {}; this.view = init.view || null; this.detail = init.detail || 0; }
}
const MODS = ['ctrlKey', 'shiftKey', 'altKey', 'metaKey'];
class MouseEvent extends UIEvent {
    constructor(type, init) {
        super(type, init);
        init = init || {};
        this.screenX = init.screenX || 0; this.screenY = init.screenY || 0;
        this.clientX = init.clientX || 0; this.clientY = init.clientY || 0;
        const sy = lx.view()[2];
        this.pageX = this.clientX; this.pageY = this.clientY + sy;
        this.x = this.clientX; this.y = this.clientY;
        this.offsetX = 0; this.offsetY = 0;
        this.movementX = 0; this.movementY = 0;
        this.button = init.button || 0;
        this.buttons = init.buttons || 0;
        this.relatedTarget = init.relatedTarget || null;
        for (const k of MODS) this[k] = !!init[k];
    }
    getModifierState(k) { return k === 'Shift' ? this.shiftKey : k === 'Control' ? this.ctrlKey : k === 'Alt' ? this.altKey : k === 'Meta' ? this.metaKey : false; }
    initMouseEvent(type, bubbles, cancelable, view, detail, sx, sy, cx, cy, ctrl, alt, shift, meta, button, rel) {
        this.initEvent(type, bubbles, cancelable);
        Object.assign(this, { view, detail, screenX: sx, screenY: sy, clientX: cx, clientY: cy, ctrlKey: ctrl, altKey: alt, shiftKey: shift, metaKey: meta, button, relatedTarget: rel });
    }
}
class PointerEvent extends MouseEvent {
    constructor(type, init) {
        super(type, init);
        init = init || {};
        this.pointerId = init.pointerId || 1;
        this.pointerType = init.pointerType || 'mouse';
        this.isPrimary = true;
        this.width = this.height = 1;
        this.pressure = this.buttons ? 0.5 : 0;
        this.tiltX = this.tiltY = this.twist = 0;
    }
    getCoalescedEvents() { return [this]; }
}
class WheelEvent extends MouseEvent {
    constructor(type, init) { super(type, init); init = init || {}; this.deltaX = init.deltaX || 0; this.deltaY = init.deltaY || 0; this.deltaZ = 0; this.deltaMode = 0; }
}
class KeyboardEvent extends UIEvent {
    constructor(type, init) {
        super(type, init);
        init = init || {};
        this.key = init.key || '';
        this.code = init.code || '';
        this.keyCode = init.keyCode || 0;
        this.which = init.which || this.keyCode;
        this.charCode = init.charCode || 0;
        this.location = 0;
        this.repeat = !!init.repeat;
        this.isComposing = false;
        for (const k of MODS) this[k] = !!init[k];
    }
    getModifierState(k) { return MouseEvent.prototype.getModifierState.call(this, k); }
    initKeyboardEvent(type, bubbles, cancelable, view, key) { this.initEvent(type, bubbles, cancelable); this.key = key || ''; }
}
class FocusEvent extends UIEvent { constructor(type, init) { super(type, init); this.relatedTarget = (init && init.relatedTarget) || null; } }
class InputEvent extends UIEvent {
    constructor(type, init) { super(type, init); init = init || {}; this.data = init.data === undefined ? null : init.data; this.inputType = init.inputType || ''; this.isComposing = false; }
}
class CustomEvent extends Event {
    constructor(type, init) { super(type, init); this.detail = init && init.detail !== undefined ? init.detail : null; }
    initCustomEvent(type, bubbles, cancelable, detail) { this.initEvent(type, bubbles, cancelable); this.detail = detail; }
}
class ErrorEvent extends Event {
    constructor(type, init) { super(type, init); init = init || {}; this.message = init.message || ''; this.filename = init.filename || ''; this.lineno = init.lineno || 0; this.colno = init.colno || 0; this.error = init.error; }
}
class ProgressEvent extends Event {
    constructor(type, init) { super(type, init); init = init || {}; this.lengthComputable = !!init.lengthComputable; this.loaded = init.loaded || 0; this.total = init.total || 0; }
}
class MessageEvent extends Event {
    constructor(type, init) { super(type, init); init = init || {}; this.data = init.data; this.origin = init.origin || ''; this.lastEventId = ''; this.source = init.source || null; this.ports = []; }
}
class PopStateEvent extends Event { constructor(type, init) { super(type, init); this.state = init && init.state !== undefined ? init.state : null; } }
class HashChangeEvent extends Event { constructor(type, init) { super(type, init); init = init || {}; this.oldURL = init.oldURL || ''; this.newURL = init.newURL || ''; } }
class PageTransitionEvent extends Event { constructor(type, init) { super(type, init); this.persisted = false; } }
class SubmitEvent extends Event { constructor(type, init) { super(type, init); this.submitter = (init && init.submitter) || null; } }
class StorageEvent extends Event { constructor(type, init) { super(type, init); Object.assign(this, { key: null, oldValue: null, newValue: null, url: '', storageArea: null }, init || {}); } }
class AnimationEvent extends Event { constructor(type, init) { super(type, init); this.animationName = (init && init.animationName) || ''; this.elapsedTime = 0; } }
class TransitionEvent extends Event { constructor(type, init) { super(type, init); this.propertyName = (init && init.propertyName) || ''; this.elapsedTime = 0; } }
class ClipboardEvent extends Event { constructor(type, init) { super(type, init); this.clipboardData = null; } }
class CompositionEvent extends UIEvent { constructor(type, init) { super(type, init); this.data = (init && init.data) || ''; } }

/* ================================================================
 * mutation observers (the changes scripts make, told in a microtask)
 * ================================================================ */
const mos = [];
let moQueued = false;
class MutationRecord { }
function record(type, target, extra) {
    if (!mos.length) return;
    for (const mo of mos) {
        for (const r of mo._regs) {
            const o = r.opts;
            if (r.node !== target && !(o.subtree && r.node.contains(target))) continue;
            if (type === 'childList' && !o.childList) continue;
            if (type === 'attributes' && (!o.attributes || (o.attributeFilter && !o.attributeFilter.includes(extra.attributeName)))) continue;
            if (type === 'characterData' && !o.characterData) continue;
            const rec = Object.assign(new MutationRecord(), { type, target, addedNodes: list([]), removedNodes: list([]), previousSibling: null,
                nextSibling: null, attributeName: null, attributeNamespace: null, oldValue: null }, extra);
            if ((type === 'attributes' && !o.attributeOldValue) || (type === 'characterData' && !o.characterDataOldValue)) rec.oldValue = null;
            mo._q.push(rec);
            break;
        }
    }
    if (!moQueued) {
        moQueued = true;
        queueMicrotask(() => {
            moQueued = false;
            for (const mo of mos.slice()) { const q = mo.takeRecords(); if (q.length) safe(mo._cb, [q, mo]); }
        });
    }
}
class MutationObserver {
    constructor(cb) { if (typeof cb !== 'function') throw new TypeError("Failed to construct 'MutationObserver'"); this._cb = cb; this._regs = []; this._q = []; }
    observe(node, opts) {
        opts = Object.assign({}, opts);
        if (opts.attributeOldValue || opts.attributeFilter) opts.attributes = true;
        if (opts.characterDataOldValue) opts.characterData = true;
        this._regs = this._regs.filter(r => r.node !== node);
        this._regs.push({ node, opts });
        if (!mos.includes(this)) mos.push(this);
    }
    disconnect() { const i = mos.indexOf(this); if (i >= 0) mos.splice(i, 1); this._regs = []; this._q = []; }
    takeRecords() { const q = this._q; this._q = []; return q; }
}

/* ================================================================
 * nodes
 * ================================================================ */
class Node extends EventTarget {
    get nodeType() { return lx.type(this[N]); }
    get nodeName() {
        switch (this.nodeType) {
        case 1: return this.tagName;
        case 3: return '#text';
        case 8: return '#comment';
        case 9: return '#document';
        default: return '#document-fragment';
        }
    }
    get parentNode() { return W(lx.parent(this[N])); }
    get parentElement() { const p = lx.parent(this[N]); return p && lx.type(p) === 1 ? W(p) : null; }
    get firstChild() { return W(lx.first(this[N])); }
    get lastChild() { return W(lx.last(this[N])); }
    get nextSibling() { return W(lx.next(this[N])); }
    get previousSibling() { return W(lx.prev(this[N])); }
    get childNodes() { return list(kidIds(this[N])); }
    hasChildNodes() { return !!lx.first(this[N]); }
    get ownerDocument() { return this === document ? null : document; }
    get isConnected() { return lx.within(this[N], docIds[0]); }
    get baseURI() { return lx.base(); }
    get textContent() { return this.nodeType === 9 ? null : lx.textof(this[N]); }
    set textContent(v) { setText(this, sv(v)); }
    get nodeValue() { const t = this.nodeType; return t === 3 || t === 8 ? lx.data(this[N]) : null; }
    set nodeValue(v) { const t = this.nodeType; if (t === 3 || t === 8) this.data = v; }
    appendChild(c) { return insert(this, c, null); }
    insertBefore(c, ref) { return insert(this, c, ref || null); }
    removeChild(c) {
        if (!(c instanceof Node) || lx.parent(c[N]) !== this[N]) throw new DOMException("The node to be removed is not a child of this node.", 'NotFoundError');
        removeNode(c);
        return c;
    }
    replaceChild(nc, oc) {
        if (!(oc instanceof Node) || lx.parent(oc[N]) !== this[N]) throw new DOMException("The node to be replaced is not a child of this node.", 'NotFoundError');
        if (nc === oc) return oc;
        insert(this, nc, oc);
        removeNode(oc);
        return oc;
    }
    cloneNode(deep) {
        const c = W(lx.clone(this[N], !!deep));
        if (this instanceof HTMLInputElement) c.value = this.value;
        return c;
    }
    contains(o) { return o instanceof Node && lx.within(o[N], this[N]); }
    getRootNode() { let n = this; for (let p; (p = n.parentNode); n = p) ; return n; }
    normalize() {
        for (let c = this.firstChild; c; ) {
            const nx = c.nextSibling;
            if (c.nodeType === 3) {
                if (nx && nx.nodeType === 3) { c.data += nx.data; nx.remove(); continue; }
                if (!c.data) c.remove();
            } else if (c.nodeType === 1) c.normalize();
            c = nx;
        }
    }
    isSameNode(o) { return this === o; }
    isEqualNode(o) { return o instanceof Node && o.nodeType === this.nodeType && (this.nodeType === 1 ? o.outerHTML === this.outerHTML : o.textContent === this.textContent); }
    compareDocumentPosition(o) {
        if (o === this) return 0;
        if (this.contains(o)) return 20;
        if (o.contains(this)) return 10;
        const a = [], b = [];
        for (let n = this; n; n = n.parentNode) a.unshift(n);
        for (let n = o; n; n = n.parentNode) b.unshift(n);
        if (a[0] !== b[0]) return 33;
        let i = 0;
        while (a[i] === b[i]) i++;
        for (let s = a[i]; s; s = s.nextSibling) if (s === b[i]) return 4;
        return 2;
    }
    lookupNamespaceURI() { return null; }
    isDefaultNamespace() { return true; }
}
Object.assign(Node, { ELEMENT_NODE: 1, ATTRIBUTE_NODE: 2, TEXT_NODE: 3, CDATA_SECTION_NODE: 4, PROCESSING_INSTRUCTION_NODE: 7, COMMENT_NODE: 8,
    DOCUMENT_NODE: 9, DOCUMENT_TYPE_NODE: 10, DOCUMENT_FRAGMENT_NODE: 11, DOCUMENT_POSITION_DISCONNECTED: 1, DOCUMENT_POSITION_PRECEDING: 2,
    DOCUMENT_POSITION_FOLLOWING: 4, DOCUMENT_POSITION_CONTAINS: 8, DOCUMENT_POSITION_CONTAINED_BY: 16, DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC: 32 });
for (const k of Object.keys(Node)) if (typeof Node[k] === 'number') Node.prototype[k] = Node[k];

/* c into p before ref: the tree changed; what came in is looked at */
function insert(p, c, ref) {
    const cid = nodeOf(c, 'insertBefore');
    if (ref && lx.parent(ref[N]) !== p[N]) throw new DOMException("The node before which the new node is to be inserted is not a child of this node.", 'NotFoundError');
    if (c === ref) return c;
    if (c === p || lx.within(p[N], cid)) throw new DOMException("The new child element contains the parent.", 'HierarchyRequestError');
    const frag = lx.type(cid) === 11;
    const ids = frag ? kidIds(cid) : [cid];
    if (!frag && lx.parent(cid) && mos.length) { const op = c.parentNode; record('childList', op, { removedNodes: list([cid]) }); }
    const prev = mos.length ? (ref ? ref.previousSibling : p.lastChild) : null;
    lx.insert(p[N], cid, ref ? ref[N] : 0);
    if (mos.length && ids.length) record('childList', p, { addedNodes: list(ids), previousSibling: prev, nextSibling: ref });
    came(p, ids, false);
    return c;
}
function removeNode(c) {
    const p = c.parentNode;
    if (!p) return;
    const prev = mos.length ? c.previousSibling : null, next = mos.length ? c.nextSibling : null;
    lx.remove(c[N]);
    if (mos.length) record('childList', p, { removedNodes: list([c[N]]), previousSibling: prev, nextSibling: next });
    if (ceDefs.size) went(c);
}
function setText(n, v) {
    const t = n.nodeType;
    if (t === 3 || t === 8) { n.data = v; return; }
    const id = n[N], old = mos.length ? kidIds(id) : null;
    lx.empty(id);
    let added = [];
    if (v !== '') { const tn = lx.newtext(v, 3); lx.insert(id, tn, 0); added = [tn]; }
    if (old && (old.length || added.length)) record('childList', n, { removedNodes: list(old), addedNodes: list(added) });
    came(n, added, false);
}
function setHTML(el, html, run) {
    const id = el[N], old = mos.length ? kidIds(id) : null;
    lx.empty(id);
    const f = lx.parse(sv(html), run ? 1 : 0), ids = kidIds(f);
    lx.insert(id, f, 0);
    if (old && (old.length || ids.length)) record('childList', el, { removedNodes: list(old), addedNodes: list(ids) });
    came(el, ids, false);
}

/* what came into p (node numbers): scripts to run, styles to apply,
 * custom elements to wake (when it's all in the page) */
const fedStyles = new Map(), loadedLinks = new Set();
let scriptQ = [];
function came(p, ids, sync) {
    if (!lx.within(p[N], docIds[0])) return;
    const pt = lx.type(p[N]) === 1 ? lx.atom(lx.tag(p[N])) : '';
    if (pt === 'style') feedStyle(p);
    if (pt === 'script' && !(lx.flags(p[N]) & RAN)) queueScript(p, sync);
    for (const id of ids) {
        if (lx.type(id) !== 1) continue;
        for (const e of lx.scan(id)) {
            const tag = lx.atom(lx.tag(e)), w = W(e);
            if (tag === 'script') { if (!(lx.flags(e) & RAN)) queueScript(w, sync); }
            else if (tag === 'style') feedStyle(w);
            else if (tag === 'link') linkCame(w);
            else if (tag === 'iframe') setTimeout(() => fire(w, 'load'), 0);
            else if (tag === 'img') { if (w.getAttribute('src')) setTimeout(() => fire(w, 'load'), 0); }
            else if (ceDefs.has(tag) && typeof w.connectedCallback === 'function') safe(w.connectedCallback, [], w);
        }
    }
}
function went(c) {
    if (c.nodeType !== 1) return;
    for (const e of lx.scan(c[N])) { const w = nodes[e]; if (w && typeof w.disconnectedCallback === 'function') safe(w.disconnectedCallback, [], w); }
}
function feedStyle(el) {
    const id = el[N], t = lx.textof(id), had = fedStyles.get(id) || '';
    if (t === had) return;
    fedStyles.set(id, t);
    lx.addcss(t.startsWith(had) ? t.slice(had.length) : t, null);
}
function linkCame(el) {
    const rel = (el.getAttribute('rel') || '').toLowerCase().split(/\s+/), href = el.getAttribute('href');
    if (rel.includes('stylesheet') && href && !loadedLinks.has(el[N])) {
        loadedLinks.add(el[N]);
        lx.addcss('', href);
    }
    if (href && (rel.includes('stylesheet') || rel.includes('preload') || rel.includes('prefetch') || rel.includes('modulepreload')))
        setTimeout(() => fire(el, 'load'), 0);
}
function queueScript(el, sync) {
    const kind = scriptKind(el);
    if (!kind) return;
    if (el.getAttribute('src') === null && !lx.textof(el[N]).trim()) return;   // (empty: not yet)
    if (sync) runScript(el);
    else { scriptQ.push(el); lx.due(lx.now()); }
}
const JS_TYPES = /^(|text\/javascript|application\/javascript|text\/ecmascript|application\/ecmascript|application\/x-javascript|text\/x-javascript|text\/jscript|text\/livescript|module)$/;
function scriptKind(el) {
    if (el.hasAttribute('nomodule')) return null;
    const t = (el.getAttribute('type') || '').trim().toLowerCase().split(';')[0];
    if (!JS_TYPES.test(t)) return null;
    const lang = el.getAttribute('language');
    if (lang && !/^javascript/i.test(lang)) return null;
    return t === 'module' ? 'module' : 'classic';
}
function runScript(el) {
    const id = el[N];
    if (lx.flags(id) & RAN) return;
    lx.setflag(id, RAN);
    if (!el.isConnected) return;
    const kind = scriptKind(el);
    if (!kind) return;
    const src = el.getAttribute('src');
    let code, name;
    if (src !== null) {
        if (!src.trim()) { setTimeout(() => fire(el, 'error'), 0); return; }
        name = lx.resolve(src);
        code = lx.load(name);
        if (code === null) { lx.log(87, 'Not loaded: ' + name); fire(el, 'error'); return; }
    } else { code = lx.textof(id); name = lx.url(); }
    const prev = curScript;
    curScript = kind === 'module' ? null : el;
    lx.run(code, name, kind === 'module' ? 1 : 0);
    curScript = prev;
    if (src !== null) fire(el, 'load');
}
function drainScripts() {
    while (scriptQ.length) runScript(scriptQ.shift());
}

class CharacterData extends Node {
    get data() { return lx.data(this[N]); }
    set data(v) {
        v = sv(v);
        const old = mos.length ? this.data : null;
        lx.setdata(this[N], v);
        if (mos.length) record('characterData', this, { oldValue: old });
        const p = this.parentNode;
        if (p && p.localName === 'style' && p.isConnected) feedStyle(p);
        if (p && p.localName === 'script' && p.isConnected && !(lx.flags(p[N]) & RAN)) queueScript(p, false);
    }
    get length() { return this.data.length; }
    get textContent() { return this.data; }
    set textContent(v) { this.data = v; }
    appendData(s) { this.data += sv(s); }
    insertData(o, s) { const d = this.data; this.data = d.slice(0, o) + sv(s) + d.slice(o); }
    deleteData(o, n) { const d = this.data; this.data = d.slice(0, o) + d.slice(o + n); }
    replaceData(o, n, s) { const d = this.data; this.data = d.slice(0, o) + sv(s) + d.slice(o + n); }
    substringData(o, n) { return this.data.substr(o, n); }
}
class Text extends CharacterData {
    constructor(d) { super(); const id = lx.newtext(sv(d), 3); this[N] = id; nodes[id] = this; }
    get wholeText() { return this.data; }
    get assignedSlot() { return null; }
    splitText(off) {
        const d = this.data, t = new Text(d.slice(off));
        this.data = d.slice(0, off);
        if (this.parentNode) this.parentNode.insertBefore(t, this.nextSibling);
        return t;
    }
}
class CDATASection extends Text { }
class Comment extends CharacterData {
    constructor(d) { super(); const id = lx.newtext(sv(d), 8); this[N] = id; nodes[id] = this; }
}
class DocumentFragment extends Node {
    constructor() { super(); const id = lx.newfrag(11); this[N] = id; nodes[id] = this; }
    get innerHTML() { return lx.html(this[N], 0); }
    set innerHTML(v) { setHTML(this, v); }
    getElementById(id) { return this.querySelector('#' + CSS.escape(String(id))); }
}
class ShadowRoot extends DocumentFragment {
    get host() { return W(this[N]); }
    get mode() { return 'open'; }
    get innerHTML() { return lx.html(this[N], 0); }
    set innerHTML(v) { setHTML(W(this[N]), v); }
    get activeElement() { return null; }
    get adoptedStyleSheets() { return []; }
    set adoptedStyleSheets(v) { for (const s of v || []) if (s && s._text) lx.addcss(s._text, null); }
}

/* ParentNode, ChildNode: in elements, documents, fragments */
const parentNode = {
    get children() { return list(kidIds(this[N], 1)); },
    get firstElementChild() { return W(kidIds(this[N], 1)[0] || 0); },
    get lastElementChild() { const k = kidIds(this[N], 1); return W(k[k.length - 1] || 0); },
    get childElementCount() { return kidIds(this[N], 1).length; },
    querySelector(s) { return W(query(this, s, 0)); },
    querySelectorAll(s) { return list(query(this, s, 1)); },
    getElementsByTagName(t) { return list(lx.query(this[N], -1, 1, String(t).toLowerCase())); },
    getElementsByClassName(c) { return list(lx.query(this[N], -2, 1, String(c))); },
    append(...ns) { for (const n of ns) this.appendChild(toNode(n)); },
    prepend(...ns) { const f = this.firstChild; for (const n of ns) this.insertBefore(toNode(n), f); },
    replaceChildren(...ns) { setText(this, ''); this.append(...ns); },
};
const childNode = {
    remove() { if (this.parentNode) removeNode(this); },
    before(...ns) { const p = this.parentNode; if (p) for (const n of ns) p.insertBefore(toNode(n), this); },
    after(...ns) { const p = this.parentNode; if (!p) return; const r = this.nextSibling; for (const n of ns) p.insertBefore(toNode(n), r); },
    replaceWith(...ns) {
        const p = this.parentNode;
        if (!p) return;
        let r = this.nextSibling;
        while (r && ns.includes(r)) r = r.nextSibling;
        removeNode(this);
        for (const n of ns) p.insertBefore(toNode(n), r);
    },
    get nextElementSibling() { for (let n = lx.next(this[N]); n; n = lx.next(n)) if (lx.type(n) === 1) return W(n); return null; },
    get previousElementSibling() { for (let n = lx.prev(this[N]); n; n = lx.prev(n)) if (lx.type(n) === 1) return W(n); return null; },
};
function mixin(C, m) { for (const k of Object.keys(Object.getOwnPropertyDescriptors(m))) Object.defineProperty(C.prototype, k, Object.getOwnPropertyDescriptor(m, k)); }

/* selectors: compiled once by css.h, kept */
const selCache = new Map();
function selh(s) {
    s = String(s);
    let h = selCache.get(s);
    if (h === undefined) {
        h = s.trim() ? lx.sel(s.trim()) : -1;
        if (h < 0) throw new DOMException(`Failed to execute 'querySelector': '${s}' is not a valid selector.`, 'SyntaxError');
        selCache.set(s, h);
    }
    return h;
}
let scopeN = 0;
function query(root, s, all) {
    s = String(s);
    if (s.includes(':scope') && root instanceof Element) {            // (:scope: root, marked for a moment)
        const g = lx.gen(), mark = 'lx-scope-' + (++scopeN);
        lx.setattr(root[N], mark, '');
        try { return lx.query(root.parentNode ? root.parentNode[N] : root[N], selh(s.replace(/:scope/g, '[' + mark + ']')), all); }
        finally { lx.delattr(root[N], mark); lx.gen(g); }
    }
    return lx.query(root[N], selh(s), all);
}

/* ================================================================
 * elements
 * ================================================================ */
const CL = Symbol('classList'), STY = Symbol('style'), DS = Symbol('dataset'), SR = Symbol('shadow');
class Element extends Node {
    get tagName() { const t = lx.atom(lx.tag(this[N])); return this instanceof SVGElement && t !== 'svg' ? t : t.toUpperCase(); }
    get localName() { return lx.atom(lx.tag(this[N])); }
    get namespaceURI() { return this instanceof SVGElement ? 'http://www.w3.org/2000/svg' : 'http://www.w3.org/1999/xhtml'; }
    get prefix() { return null; }
    get id() { return this.getAttribute('id') || ''; }
    set id(v) { this.setAttribute('id', v); }
    get className() { return this.getAttribute('class') || ''; }
    set className(v) { this.setAttribute('class', v); }
    get classList() { return this[CL] || (hide(this, CL, new DOMTokenList(this, 'class')), this[CL]); }
    set classList(v) { this.setAttribute('class', v); }
    get slot() { return this.getAttribute('slot') || ''; }
    getAttribute(n) { return lx.getattr(this[N], String(n)); }
    getAttributeNS(ns, n) { return this.getAttribute(n); }
    hasAttribute(n) { return lx.getattr(this[N], String(n)) !== null; }
    hasAttributeNS(ns, n) { return this.hasAttribute(n); }
    hasAttributes() { return lx.attrs(this[N]).length > 0; }
    getAttributeNames() { return lx.attrs(this[N]).filter((x, i) => !(i & 1)); }
    setAttribute(n, v) {
        n = String(n).toLowerCase();
        v = String(v);
        const watch = mos.length || ceDefs.size || n === 'src' || n === 'rel' || n === 'href';
        const old = watch ? lx.getattr(this[N], n) : null;
        lx.setattr(this[N], n, v);
        if (watch) attrChanged(this, n, old, v);
    }
    setAttributeNS(ns, n, v) { this.setAttribute(String(n).replace(/^.*:/, ''), v); }
    removeAttribute(n) {
        n = String(n).toLowerCase();
        const old = lx.getattr(this[N], n);
        if (old === null) return;
        lx.delattr(this[N], n);
        attrChanged(this, n, old, null);
    }
    removeAttributeNS(ns, n) { this.removeAttribute(n); }
    toggleAttribute(n, force) {
        const has = this.hasAttribute(n);
        if (force === undefined ? has : !force) { if (has) this.removeAttribute(n); return false; }
        if (!has) this.setAttribute(n, '');
        return true;
    }
    get attributes() {
        const a = lx.attrs(this[N]), r = new NamedNodeMap();
        for (let i = 0; i < a.length; i += 2) { const at = new Attr(a[i], a[i + 1], this); r.push(at); if (!(a[i] in r)) hide(r, a[i], at); }
        return r;
    }
    getAttributeNode(n) { const v = this.getAttribute(n); return v === null ? null : new Attr(String(n).toLowerCase(), v, this); }
    setAttributeNode(a) { this.setAttribute(a.name, a.value); return null; }
    get innerHTML() { return lx.html(this[N], 0); }
    set innerHTML(v) { setHTML(this, v); }
    get outerHTML() { return lx.html(this[N], 1); }
    set outerHTML(v) {
        const p = this.parentNode;
        if (!p) return;
        const f = W(lx.parse(sv(v), 0));
        p.insertBefore(f, this);
        removeNode(this);
    }
    insertAdjacentHTML(pos, html) { adjacent(this, pos, W(lx.parse(sv(html), 0))); }
    insertAdjacentElement(pos, el) { return adjacent(this, pos, el); }
    insertAdjacentText(pos, t) { adjacent(this, pos, document.createTextNode(t)); }
    matches(s) { return lx.match(this[N], selh(s)); }
    webkitMatchesSelector(s) { return this.matches(s); }
    msMatchesSelector(s) { return this.matches(s); }
    closest(s) { return W(lx.closest(this[N], selh(s))); }
    getBoundingClientRect() { const r = lx.rect(this[N]), v = lx.view(); return new DOMRect(r[0], r[1] - v[2], r[2], r[3]); }
    getClientRects() { const r = this.getBoundingClientRect(); return r.width || r.height ? [r] : []; }
    get clientWidth() { return this === document.documentElement ? lx.view()[0] : lx.rect(this[N])[2]; }
    get clientHeight() { return this === document.documentElement ? lx.view()[1] : lx.rect(this[N])[3]; }
    get clientTop() { return 0; }
    get clientLeft() { return 0; }
    get scrollWidth() { return this === document.documentElement || this === document.body ? lx.view()[0] : lx.rect(this[N])[2]; }
    get scrollHeight() { return this === document.documentElement || this === document.body ? Math.max(lx.view()[3], lx.view()[1]) : lx.rect(this[N])[3]; }
    get scrollTop() { return this === document.documentElement || this === document.body ? lx.view()[2] : this._st || 0; }
    set scrollTop(v) { if (this === document.documentElement || this === document.body) lx.scroll(+v || 0); else hide(this, '_st', +v || 0); }
    get scrollLeft() { return 0; }
    set scrollLeft(v) { }
    scrollIntoView(o) {
        const r = lx.rect(this[N]), v = lx.view();
        let y = r[1];
        if (o && typeof o === 'object' && o.block === 'center') y = r[1] - (v[1] - r[3]) / 2;
        else if (o && typeof o === 'object' && o.block === 'end' || o === false) y = r[1] + r[3] - v[1];
        lx.scroll(Math.max(0, y | 0));
    }
    scrollIntoViewIfNeeded() { this.scrollIntoView(); }
    scrollTo(x, y) { if (this === document.documentElement || this === document.body) G.scrollTo(x, y); }
    scroll(x, y) { this.scrollTo(x, y); }
    scrollBy(x, y) { if (this === document.documentElement || this === document.body) G.scrollBy(x, y); }
    attachShadow(o) {
        const s = Object.create(ShadowRoot.prototype);
        s[N] = this[N];
        if (!o || o.mode !== 'closed') hide(this, SR, s);
        return s;
    }
    get shadowRoot() { return this[SR] || null; }
    get assignedSlot() { return null; }
    animate() {
        const a = new EventTarget();
        Object.assign(a, { finished: Promise.resolve(a), ready: Promise.resolve(a), playState: 'finished', currentTime: 0, onfinish: null,
            cancel() { }, play() { }, pause() { }, finish() { }, reverse() { }, persist() { }, commitStyles() { } });
        setTimeout(() => { if (typeof a.onfinish === 'function') safe(a.onfinish, [new Event('finish')], a); fire(a, 'finish'); }, 0);
        return a;
    }
    getAnimations() { return []; }
    requestFullscreen() { return Promise.reject(new TypeError('Fullscreen is not supported')); }
    requestPointerLock() { }
    setPointerCapture() { }
    releasePointerCapture() { }
    hasPointerCapture() { return false; }
    checkVisibility() { const r = lx.rect(this[N]); return r[2] > 0 || r[3] > 0; }
    computedStyleMap() { return new Map(); }
}
mixin(Element, parentNode);
mixin(Element, childNode);
mixin(CharacterData, childNode);
function adjacent(el, pos, n) {
    switch (String(pos).toLowerCase()) {
    case 'beforebegin': if (el.parentNode) el.parentNode.insertBefore(n, el); break;
    case 'afterbegin': el.insertBefore(n, el.firstChild); break;
    case 'beforeend': el.appendChild(n); break;
    case 'afterend': if (el.parentNode) el.parentNode.insertBefore(n, el.nextSibling); break;
    default: throw new DOMException(`'${pos}' is not a valid position.`, 'SyntaxError');
    }
    return n;
}
function attrChanged(el, n, old, v) {
    if (mos.length) record('attributes', el, { attributeName: n, oldValue: old });
    const C = ceDefs.get(el.localName);
    if (C && typeof el.attributeChangedCallback === 'function') {
        const obs = C.observedAttributes;
        if (obs && Array.from(obs).includes(n)) safe(el.attributeChangedCallback, [n, old, v], el);
    }
    const tag = el.localName;
    if (tag === 'link' && (n === 'rel' || n === 'href') && el.isConnected) linkCame(el);
    else if (tag === 'script' && n === 'src' && el.isConnected && !(lx.flags(el[N]) & RAN)) queueScript(el, false);
    else if ((tag === 'img' || tag === 'iframe') && n === 'src' && v) setTimeout(() => fire(el, 'load'), 0);
    if (el[STY] && n === 'style') el[STY]._src = null;
}
class Attr extends Node {
    constructor(name, value, owner) { super(); hide(this, '_n', name); hide(this, '_v', value); hide(this, '_o', owner); }
    get name() { return this._n; }
    get localName() { return this._n; }
    get nodeName() { return this._n; }
    get nodeType() { return 2; }
    get value() { return this._v; }
    set value(v) { this._v = String(v); if (this._o) this._o.setAttribute(this._n, v); }
    get nodeValue() { return this._v; }
    get textContent() { return this._v; }
    get ownerElement() { return this._o; }
    get specified() { return true; }
    get namespaceURI() { return null; }
}
class NamedNodeMap extends Array {
    getNamedItem(n) { n = String(n).toLowerCase(); return this.find(a => a.name === n) || null; }
    item(i) { return this[i] || null; }
    static get [Symbol.species]() { return Array; }
}
class DOMTokenList {
    constructor(el, attr) { hide(this, '_el', el); hide(this, '_a', attr); }
    _get() { const s = this._el.getAttribute(this._a); return s ? s.split(/\s+/).filter(Boolean) : []; }
    _set(l) { this._el.setAttribute(this._a, l.join(' ')); }
    get length() { return this._get().length; }
    get value() { return this._el.getAttribute(this._a) || ''; }
    set value(v) { this._el.setAttribute(this._a, v); }
    item(i) { return this._get()[i] || null; }
    contains(t) { return this._get().includes(String(t)); }
    add(...ts) {
        const l = this._get();
        let ch = false;
        for (let t of ts) { t = String(t); if (!t || /\s/.test(t)) throw new DOMException('The token provided is not valid.', 'InvalidCharacterError'); if (!l.includes(t)) { l.push(t); ch = true; } }
        if (ch || !this._el.hasAttribute(this._a)) this._set(l);
    }
    remove(...ts) {
        const l = this._get(), r = l.filter(x => !ts.map(String).includes(x));
        if (r.length !== l.length) this._set(r);
    }
    toggle(t, force) {
        t = String(t);
        const has = this.contains(t);
        if (force === undefined ? has : !force) { if (has) this.remove(t); return false; }
        if (!has) this.add(t);
        return true;
    }
    replace(a, b) { const l = this._get(), i = l.indexOf(String(a)); if (i < 0) return false; l[i] = String(b); this._set([...new Set(l)]); return true; }
    supports() { return true; }
    toString() { return this.value; }
    forEach(f, self) { this._get().forEach((t, i) => f.call(self, t, i, this)); }
    entries() { return this._get().entries(); }
    keys() { return this._get().keys(); }
    values() { return this._get().values(); }
    [Symbol.iterator]() { return this._get()[Symbol.iterator](); }
}

/* el.style: what style="..." says, as properties */
function parseDecls(s) {
    const m = new Map();
    let depth = 0, q = '', start = 0;
    const put = part => {
        const i = part.indexOf(':');
        if (i < 0) return;
        let k = part.slice(0, i).trim(), v = part.slice(i + 1).trim(), imp = false;
        if (!k.startsWith('--')) k = k.toLowerCase();
        const im = /\s*!\s*important\s*$/i.exec(v);
        if (im) { imp = true; v = v.slice(0, im.index).trim(); }
        if (k) m.set(k, { v, imp });
    };
    for (let i = 0; i < s.length; i++) {
        const c = s[i];
        if (q) { if (c === q) q = ''; continue; }
        if (c === '"' || c === "'") q = c;
        else if (c === '(') depth++;
        else if (c === ')') depth--;
        else if (c === ';' && depth <= 0) { put(s.slice(start, i)); start = i + 1; }
    }
    put(s.slice(start));
    return m;
}
const declText = m => Array.from(m, ([k, d]) => `${k}: ${d.v}${d.imp ? ' !important' : ''};`).join(' ');
class CSSStyleDeclaration {
    constructor(el) { hide(this, '_el', el); hide(this, '_src', null); hide(this, '_m', new Map()); }
    _map() {
        const s = this._el ? this._el.getAttribute('style') || '' : '';
        if (s !== this._src) { this._src = s; this._m = parseDecls(s); }
        return this._m;
    }
    _write() {
        const t = declText(this._m);
        this._src = t;
        if (!this._el) return;
        if (t) this._el.setAttribute('style', t); else this._el.removeAttribute('style');
        this._src = t;
    }
    get cssText() { return declText(this._map()); }
    set cssText(v) { this._m = parseDecls(sv(v)); this._write(); }
    get length() { return this._map().size; }
    item(i) { return Array.from(this._map().keys())[i] || ''; }
    getPropertyValue(k) { const d = this._map().get(k.startsWith('--') ? k : kebab(k).toLowerCase()); return d ? d.v : ''; }
    getPropertyPriority(k) { const d = this._map().get(k); return d && d.imp ? 'important' : ''; }
    setProperty(k, v, pri) {
        k = String(k);
        if (!k.startsWith('--')) k = k.toLowerCase();
        const m = this._map();
        v = v == null ? '' : String(v).trim();
        if (v === '') { if (!m.has(k)) return; m.delete(k); }
        else { const d = m.get(k); if (d && d.v === v && d.imp === (pri === 'important')) return; m.set(k, { v, imp: pri === 'important' }); }
        this._write();
    }
    removeProperty(k) { const m = this._map(), d = m.get(k); if (!d) return ''; m.delete(k); this._write(); return d.v; }
}
const styleProxy = {
    get(t, k, r) {
        if (typeof k !== 'string' || k in t) return Reflect.get(t, k, r);
        if (/^\d+$/.test(k)) return t.item(+k);
        if (k === 'cssFloat') k = 'float';
        return t.getPropertyValue(kebab(k));
    },
    set(t, k, v, r) {
        if (typeof k !== 'string' || k in t) return Reflect.set(t, k, v, r);
        if (k === 'cssFloat') k = 'float';
        t.setProperty(kebab(k), typeof v === 'number' && v !== 0 && /^(width|height|top|left|right|bottom|margin|padding|font-size|max-|min-)/.test(kebab(k)) ? v + 'px' : v);
        return true;
    },
    has(t, k) { return typeof k === 'string' ? true : k in t; },
};
const dsProxy = {
    get(t, k) { if (typeof k !== 'string') return undefined; const v = t.getAttribute('data-' + kebab(k)); return v === null ? undefined : v; },
    set(t, k, v) { t.setAttribute('data-' + kebab(k), v); return true; },
    deleteProperty(t, k) { t.removeAttribute('data-' + kebab(k)); return true; },
    has(t, k) { return typeof k === 'string' && t.hasAttribute('data-' + kebab(k)); },
    ownKeys(t) { return t.getAttributeNames().filter(n => n.startsWith('data-')).map(n => camel(n.slice(5))); },
    getOwnPropertyDescriptor(t, k) { const v = dsProxy.get(t, k); return v === undefined ? undefined : { value: v, writable: true, enumerable: true, configurable: true }; },
};

/* HTML elements: the attributes they reflect, the on... handlers */
const EVENTS = ['abort', 'animationend', 'animationiteration', 'animationstart', 'auxclick', 'beforeinput', 'blur', 'cancel', 'canplay',
    'canplaythrough', 'change', 'click', 'close', 'contextmenu', 'copy', 'cut', 'dblclick', 'drag', 'dragend', 'dragenter', 'dragleave',
    'dragover', 'dragstart', 'drop', 'durationchange', 'ended', 'error', 'focus', 'focusin', 'focusout', 'formdata', 'input', 'invalid',
    'keydown', 'keypress', 'keyup', 'load', 'loadeddata', 'loadedmetadata', 'loadstart', 'mousedown', 'mouseenter', 'mouseleave', 'mousemove',
    'mouseout', 'mouseover', 'mouseup', 'paste', 'pause', 'play', 'playing', 'pointercancel', 'pointerdown', 'pointerenter', 'pointerleave',
    'pointermove', 'pointerout', 'pointerover', 'pointerup', 'progress', 'reset', 'resize', 'scroll', 'select', 'selectionchange', 'submit',
    'toggle', 'transitionend', 'volumechange', 'waiting', 'wheel'];
const WIN_EVENTS = ['afterprint', 'beforeprint', 'beforeunload', 'hashchange', 'languagechange', 'message', 'messageerror', 'offline', 'online',
    'pagehide', 'pageshow', 'popstate', 'rejectionhandled', 'storage', 'unhandledrejection', 'unload', 'DOMContentLoaded'];
function handlers(o, list) {
    for (const t of list) {
        Object.defineProperty(o, 'on' + t, {
            get() { return (this[H] && this[H][t]) || null; },
            set(f) {
                if (!this[H]) hide(this, H, Object.create(null));
                const had = !!this[H][t];
                this[H][t] = typeof f === 'function' || (f && typeof f === 'object') ? f : null;
                if (had !== !!this[H][t]) noteWant(t, this[H][t] ? 1 : -1);
            },
            configurable: true, enumerable: true,
        });
    }
}
function reflect(C, map) {                               // {prop: 'attr'} strings; {prop: ['attr', 'bool'|'num'|'url', default]}
    for (const k of Object.keys(map)) {
        const d = map[k], a = typeof d === 'string' ? d : d[0], kind = typeof d === 'string' ? 's' : d[1], def = typeof d === 'string' ? '' : d[2];
        Object.defineProperty(C.prototype, k, {
            get() {
                const v = this.getAttribute(a);
                if (kind === 'bool') return v !== null;
                if (kind === 'num') { const n = parseInt(v, 10); return v === null || isNaN(n) ? (def === undefined ? 0 : def) : n; }
                if (kind === 'url') return v === null ? '' : lx.resolve(v);
                return v === null ? (def === undefined ? '' : def) : v;
            },
            set(v) {
                if (kind === 'bool') { if (v) this.setAttribute(a, ''); else this.removeAttribute(a); }
                else this.setAttribute(a, v);
            },
            configurable: true, enumerable: true,
        });
    }
}
class HTMLElement extends Element {
    constructor() {
        super();
        let id = upgrading;
        upgrading = 0;
        if (!id) {
            const tag = ceTags.get(new.target);
            if (!tag) throw new TypeError('Illegal constructor');
            id = lx.create(tag);
        }
        this[N] = id;
        nodes[id] = this;
    }
    get dataset() { return this[DS] || (hide(this, DS, new Proxy(this, dsProxy)), this[DS]); }
    get style() { return this[STY] ? this[STY]._p : (hide(this, STY, new CSSStyleDeclaration(this)), this[STY]._p = new Proxy(this[STY], styleProxy)); }
    set style(v) { this.setAttribute('style', v); }
    get innerText() { return innerText(this); }
    set innerText(v) { this.textContent = v; }
    get outerText() { return this.innerText; }
    set outerText(v) { this.replaceWith(document.createTextNode(sv(v))); }
    get offsetWidth() { return lx.rect(this[N])[2]; }
    get offsetHeight() { return lx.rect(this[N])[3]; }
    get offsetParent() {
        if (!lx.rect(this[N])[2] && !lx.rect(this[N])[3]) return null;
        for (let p = this.parentElement; p; p = p.parentElement) {
            if (p === document.body) return p;
            const pos = lx.cstyle(p[N]).position;
            if (pos && pos !== 'static') return p;
        }
        return document.body;
    }
    get offsetTop() { const op = this.offsetParent; return lx.rect(this[N])[1] - (op && op !== document.body ? lx.rect(op[N])[1] : 0); }
    get offsetLeft() { const op = this.offsetParent; return lx.rect(this[N])[0] - (op && op !== document.body ? lx.rect(op[N])[0] : 0); }
    get isContentEditable() { return false; }
    get contentEditable() { return this.getAttribute('contenteditable') || 'inherit'; }
    set contentEditable(v) { this.setAttribute('contenteditable', v); }
    get tabIndex() { const v = this.getAttribute('tabindex'); return v === null ? (/^(a|button|input|select|textarea)$/.test(this.localName) ? 0 : -1) : parseInt(v, 10) || 0; }
    set tabIndex(v) { this.setAttribute('tabindex', v); }
    focus() {
        const old = document.activeElement;
        if (old === this) return;
        lx.focus(this[N], 0);
        if (old && old !== document.body) { fire(old, 'blur', {}, FocusEvent); fire(old, 'focusout', { bubbles: true }, FocusEvent); }
        fire(this, 'focus', {}, FocusEvent);
        fire(this, 'focusin', { bubbles: true }, FocusEvent);
    }
    blur() { if (document.activeElement === this) { lx.focus(this[N], 1); fire(this, 'blur', {}, FocusEvent); fire(this, 'focusout', { bubbles: true }, FocusEvent); } }
    click() {
        const ev = new MouseEvent('click', { bubbles: true, cancelable: true, view: G, detail: 1 });
        const kind = this instanceof HTMLInputElement ? this.type : '';
        const was = kind === 'checkbox' || kind === 'radio' ? this.checked : null;
        if (was !== null) this.checked = kind === 'radio' ? true : !was;
        dispatch(this, ev);
        if (ev.defaultPrevented) { if (was !== null) this.checked = was; return; }
        if (was !== null && was !== this.checked) { fire(this, 'input', { bubbles: true }); fire(this, 'change', { bubbles: true }); }
        activate(this, true);
    }
    get hidden() { return this.hasAttribute('hidden'); }
    set hidden(v) { this.toggleAttribute('hidden', !!v); }
    get inert() { return this.hasAttribute('inert'); }
    set inert(v) { this.toggleAttribute('inert', !!v); }
    get draggable() { return this.getAttribute('draggable') === 'true'; }
    set draggable(v) { this.setAttribute('draggable', v ? 'true' : 'false'); }
    attachInternals() { return { setFormValue() { }, setValidity() { }, states: new Set(), form: null }; }
    showPopover() { this.setAttribute('popover-open', ''); }
    hidePopover() { this.removeAttribute('popover-open'); }
    togglePopover() { this.toggleAttribute('popover-open'); }
}
reflect(HTMLElement, { title: 'title', lang: 'lang', dir: 'dir', accessKey: 'accesskey', autofocus: ['autofocus', 'bool'], spellcheck: ['spellcheck', 'bool'],
    translate: ['translate', 'bool'], enterKeyHint: 'enterkeyhint', inputMode: 'inputmode', nonce: 'nonce', popover: 'popover' });
handlers(HTMLElement.prototype, EVENTS);
function innerText(el) {
    const blocks = /^(address|article|aside|blockquote|dd|details|dialog|div|dl|dt|fieldset|figcaption|figure|footer|form|h[1-6]|header|hr|li|main|nav|ol|p|pre|section|summary|table|tr|ul)$/;
    let out = '';
    const walk = id => {
        for (let c = lx.first(id); c; c = lx.next(c)) {
            const t = lx.type(c);
            if (t === 3) out += lx.data(c);
            else if (t === 1) {
                const tag = lx.atom(lx.tag(c));
                if (tag === 'script' || tag === 'style' || tag === 'template' || tag === 'noscript') continue;
                if (tag === 'br') { out += '\n'; continue; }
                const b = blocks.test(tag);
                if (b && out && !out.endsWith('\n')) out += '\n';
                walk(c);
                if (b && !out.endsWith('\n')) out += '\n';
                else if (tag === 'td' || tag === 'th') out += '\t';
            }
        }
    };
    walk(el[N]);
    return out.replace(/[ \t\r]*\n[ \t\r]*/g, '\n').replace(/[ \t\r]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
}
/* a click's own effect (user: what C doesn't do itself) */
function activate(el, synthetic) {
    const lab = el.closest('label');
    if (lab && !el.closest('input,select,textarea,button')) { const c = lab.control; if (c && c !== el) { c.focus(); if (c.type === 'checkbox' || c.type === 'radio' || c.localName === 'button') c.click(); } return; }
    const sm = el.closest('summary');
    if (sm && sm.parentElement && sm.parentElement.localName === 'details' && sm.parentElement.firstElementChild === sm) {
        const d = sm.parentElement;
        d.open = !d.open;
        setTimeout(() => fire(d, 'toggle'), 0);
        return;
    }
    if (!synthetic) return;
    const a = el.closest('a[href],area[href]');
    if (a) {
        const h = a.getAttribute('href');
        if (/^\s*javascript:/i.test(h)) safe(decodeURIComponent(h.replace(/^\s*javascript:/i, '')));
        else if (a.hasAttribute('download')) { }
        else lx.nav(h, 0);
        return;
    }
    const b = el.closest('button,input[type=submit],input[type=image]');
    if (b && !b.disabled && (b.localName === 'input' || (b.getAttribute('type') || 'submit').toLowerCase() === 'submit')) {
        const f = b.form;
        if (f) f.requestSubmit(b);
    } else if (b && (b.getAttribute('type') || '').toLowerCase() === 'reset' && b.form) b.form.reset();
}

/* the elements, one class for each kind */
class HTMLAnchorElement extends HTMLElement {
    get href() { const h = this.getAttribute('href'); return h === null ? '' : lx.resolve(h); }
    set href(v) { this.setAttribute('href', v); }
    get text() { return this.textContent; }
    set text(v) { this.textContent = v; }
    toString() { return this.href; }
    get relList() { return new DOMTokenList(this, 'rel'); }
}
for (const k of ['protocol', 'host', 'hostname', 'port', 'pathname', 'search', 'hash', 'origin', 'username', 'password']) {
    Object.defineProperty(HTMLAnchorElement.prototype, k, {
        get() { try { return new URL(this.href)[k]; } catch (e) { return ''; } },
        set(v) { try { const u = new URL(this.href); u[k] = v; this.href = u.href; } catch (e) { } },
        configurable: true, enumerable: true,
    });
}
reflect(HTMLAnchorElement, { target: 'target', rel: 'rel', download: 'download', hreflang: 'hreflang', type: 'type', ping: 'ping', referrerPolicy: 'referrerpolicy', name: 'name' });
class HTMLAreaElement extends HTMLAnchorElement { }
reflect(HTMLAreaElement, { alt: 'alt', coords: 'coords', shape: 'shape' });
class HTMLImageElement extends HTMLElement {
    get src() { const s = this.getAttribute('src'); return s === null ? '' : lx.resolve(s); }
    set src(v) { this.setAttribute('src', v); }
    get currentSrc() { return this.src; }
    get complete() { return true; }
    get naturalWidth() { return +this.getAttribute('width') || lx.rect(this[N])[2] || 0; }
    get naturalHeight() { return +this.getAttribute('height') || lx.rect(this[N])[3] || 0; }
    get width() { return lx.rect(this[N])[2] || +this.getAttribute('width') || 0; }
    set width(v) { this.setAttribute('width', v); }
    get height() { return lx.rect(this[N])[3] || +this.getAttribute('height') || 0; }
    set height(v) { this.setAttribute('height', v); }
    decode() { return Promise.resolve(); }
    get x() { return lx.rect(this[N])[0]; }
    get y() { return lx.rect(this[N])[1]; }
}
reflect(HTMLImageElement, { alt: 'alt', srcset: 'srcset', sizes: 'sizes', loading: 'loading', decoding: 'decoding', crossOrigin: 'crossorigin',
    useMap: 'usemap', isMap: ['ismap', 'bool'], referrerPolicy: 'referrerpolicy', fetchPriority: 'fetchpriority', name: 'name' });
class HTMLScriptElement extends HTMLElement {
    get src() { const s = this.getAttribute('src'); return s === null ? '' : lx.resolve(s); }
    set src(v) { this.setAttribute('src', v); }
    get text() { return this.textContent; }
    set text(v) { this.textContent = v; }
    static supports(t) { return t === 'classic' || t === 'module'; }
}
reflect(HTMLScriptElement, { type: 'type', async: ['async', 'bool'], defer: ['defer', 'bool'], charset: 'charset', crossOrigin: 'crossorigin',
    integrity: 'integrity', noModule: ['nomodule', 'bool'], referrerPolicy: 'referrerpolicy', event: 'event', htmlFor: 'for' });
class CSSStyleSheet {
    constructor(owner) { hide(this, '_o', owner || null); hide(this, '_text', ''); this.disabled = false; this.cssRules = []; }
    get ownerNode() { return this._o; }
    get href() { return this._o && this._o.href ? this._o.href : null; }
    get rules() { return this.cssRules; }
    get media() { return { mediaText: '', length: 0 }; }
    get type() { return 'text/css'; }
    insertRule(r, i) { r = String(r); this.cssRules.splice(i || 0, 0, { cssText: r }); lx.addcss(r, null); return i || 0; }
    addRule(sel, decl) { return this.insertRule(`${sel}{${decl}}`); }
    deleteRule(i) { this.cssRules.splice(i, 1); }
    removeRule(i) { this.deleteRule(i); }
    replaceSync(t) { this._text = String(t); if (this._o) lx.addcss(this._text, null); }
    replace(t) { this.replaceSync(t); return Promise.resolve(this); }
}
class HTMLStyleElement extends HTMLElement {
    get sheet() { return this._sheet || (hide(this, '_sheet', new CSSStyleSheet(this)), this._sheet); }
}
reflect(HTMLStyleElement, { media: 'media', type: 'type', disabled: ['disabled', 'bool'] });
class HTMLLinkElement extends HTMLElement {
    get href() { const h = this.getAttribute('href'); return h === null ? '' : lx.resolve(h); }
    set href(v) { this.setAttribute('href', v); }
    get sheet() { return /stylesheet/i.test(this.rel) ? (this._sheet || (hide(this, '_sheet', new CSSStyleSheet(this)), this._sheet)) : null; }
    get relList() { return new DOMTokenList(this, 'rel'); }
}
reflect(HTMLLinkElement, { rel: 'rel', as: 'as', media: 'media', type: 'type', crossOrigin: 'crossorigin', hreflang: 'hreflang', integrity: 'integrity',
    sizes: 'sizes', disabled: ['disabled', 'bool'], referrerPolicy: 'referrerpolicy', fetchPriority: 'fetchpriority' });
function formOf(el) {
    const f = el.getAttribute('form');
    if (f) { const e = document.getElementById(f); if (e && e.localName === 'form') return e; }
    return el.closest('form');
}
const validity = { valid: true, valueMissing: false, typeMismatch: false, patternMismatch: false, tooLong: false, tooShort: false,
    rangeUnderflow: false, rangeOverflow: false, stepMismatch: false, badInput: false, customError: false };
class FormControl extends HTMLElement {
    get form() { return formOf(this); }
    get labels() { const id = this.id, r = list([]); for (const l of document.querySelectorAll('label')) if ((id && l.htmlFor === id) || (!l.htmlFor && l.contains(this))) r.push(l); return r; }
    get validity() { return Object.assign({}, validity, this.required && !this.value ? { valid: false, valueMissing: true } : {}); }
    get validationMessage() { return this._vm || ''; }
    get willValidate() { return true; }
    checkValidity() { return this.validity.valid; }
    reportValidity() { return this.checkValidity(); }
    setCustomValidity(m) { hide(this, '_vm', String(m)); }
}
reflect(FormControl, { name: 'name', disabled: ['disabled', 'bool'], required: ['required', 'bool'], autocomplete: 'autocomplete' });
class HTMLInputElement extends FormControl {
    get type() { const t = (this.getAttribute('type') || 'text').toLowerCase(); return t; }
    set type(v) { this.setAttribute('type', v); }
    get value() { const t = this.type; if (t === 'checkbox' || t === 'radio') { const v = this.getAttribute('value'); return v === null ? 'on' : v; } return lx.ctrlget(this[N], 0); }
    set value(v) { const t = this.type; if (t === 'checkbox' || t === 'radio' || t === 'file') { if (t !== 'file') this.setAttribute('value', v); return; } lx.ctrlset(this[N], 0, sv(v)); }
    get defaultValue() { return this.getAttribute('value') || ''; }
    set defaultValue(v) { this.setAttribute('value', v); }
    get checked() { return lx.ctrlget(this[N], 1); }
    set checked(v) { lx.ctrlset(this[N], 1, !!v); }
    get defaultChecked() { return this.hasAttribute('checked'); }
    set defaultChecked(v) { this.toggleAttribute('checked', !!v); }
    get valueAsNumber() { const n = parseFloat(this.value); return isNaN(n) ? NaN : n; }
    set valueAsNumber(v) { this.value = String(v); }
    get valueAsDate() { const d = new Date(this.value); return isNaN(d) ? null : d; }
    set valueAsDate(d) { this.value = d ? d.toISOString().slice(0, 10) : ''; }
    get files() { return Object.assign([], { item: () => null }); }
    get selectionStart() { return this.value.length; }
    set selectionStart(v) { }
    get selectionEnd() { return this.value.length; }
    set selectionEnd(v) { }
    get selectionDirection() { return 'none'; }
    get list() { const l = this.getAttribute('list'); return l ? document.getElementById(l) : null; }
    select() { this.focus(); }
    setSelectionRange() { }
    setRangeText(t) { this.value = t; }
    stepUp(n) { this.valueAsNumber = (this.valueAsNumber || 0) + (n || 1) * (parseFloat(this.step) || 1); }
    stepDown(n) { this.stepUp(-(n || 1)); }
    showPicker() { }
}
reflect(HTMLInputElement, { placeholder: 'placeholder', readOnly: ['readonly', 'bool'], min: 'min', max: 'max', step: 'step', pattern: 'pattern',
    maxLength: ['maxlength', 'num', -1], minLength: ['minlength', 'num', -1], size: ['size', 'num', 20], multiple: ['multiple', 'bool'],
    accept: 'accept', alt: 'alt', src: ['src', 'url'], formAction: 'formaction', formMethod: 'formmethod', formNoValidate: ['formnovalidate', 'bool'],
    formTarget: 'formtarget', inputMode: 'inputmode', dirName: 'dirname', indeterminate: ['indeterminate', 'bool'], capture: 'capture' });
class HTMLTextAreaElement extends FormControl {
    get type() { return 'textarea'; }
    get value() { return lx.ctrlget(this[N], 0); }
    set value(v) { lx.ctrlset(this[N], 0, sv(v)); }
    get defaultValue() { return this.textContent; }
    set defaultValue(v) { this.textContent = v; }
    get textLength() { return this.value.length; }
    get selectionStart() { return this.value.length; }
    set selectionStart(v) { }
    get selectionEnd() { return this.value.length; }
    set selectionEnd(v) { }
    select() { this.focus(); }
    setSelectionRange() { }
    setRangeText(t) { this.value = t; }
}
reflect(HTMLTextAreaElement, { placeholder: 'placeholder', readOnly: ['readonly', 'bool'], rows: ['rows', 'num', 2], cols: ['cols', 'num', 20],
    maxLength: ['maxlength', 'num', -1], minLength: ['minlength', 'num', -1], wrap: 'wrap' });
class HTMLSelectElement extends FormControl {
    get type() { return this.multiple ? 'select-multiple' : 'select-one'; }
    get options() {
        const o = list(lx.query(this[N], -1, 1, 'option'));
        const sel = this;
        o.add = (opt, before) => sel.add(opt, before);
        o.remove = i => sel.remove(i);
        Object.defineProperty(o, 'selectedIndex', { get: () => sel.selectedIndex, set: v => { sel.selectedIndex = v; } });
        return o;
    }
    get length() { return lx.query(this[N], -1, 1, 'option').length; }
    set length(n) { const o = this.options; while (o.length > n) o.pop().remove(); }
    get selectedIndex() { return lx.ctrlget(this[N], 2); }
    set selectedIndex(i) { lx.ctrlset(this[N], 2, i | 0); }
    get value() { const o = this.options[this.selectedIndex]; return o ? o.value : ''; }
    set value(v) { const i = this.options.findIndex(o => o.value === String(v)); this.selectedIndex = i; }
    get selectedOptions() { const o = this.options[this.selectedIndex]; return list(o ? [o[N]] : []); }
    item(i) { return this.options[i] || null; }
    namedItem(n) { return this.options.namedItem(n); }
    add(opt, before) { this.insertBefore(opt, typeof before === 'number' ? this.options[before] || null : before || null); }
    remove(i) { if (i === undefined) { childNode.remove.call(this); return; } const o = this.options[i]; if (o) o.remove(); }
}
reflect(HTMLSelectElement, { multiple: ['multiple', 'bool'], size: ['size', 'num', 0] });
class HTMLOptionElement extends HTMLElement {
    get value() { const v = this.getAttribute('value'); return v === null ? this.text : v; }
    set value(v) { this.setAttribute('value', v); }
    get text() { return this.textContent.replace(/\s+/g, ' ').trim(); }
    set text(v) { this.textContent = v; }
    get label() { return this.getAttribute('label') || this.text; }
    set label(v) { this.setAttribute('label', v); }
    get select() { return this.closest('select'); }
    get index() { const s = this.select; return s ? s.options.indexOf(this) : 0; }
    get selected() { const s = this.select; return s ? s.selectedIndex === this.index : this.hasAttribute('selected'); }
    set selected(v) { const s = this.select; if (s && v) s.selectedIndex = this.index; else if (!s) this.toggleAttribute('selected', !!v); }
    get defaultSelected() { return this.hasAttribute('selected'); }
    set defaultSelected(v) { this.toggleAttribute('selected', !!v); }
    get form() { const s = this.select; return s ? s.form : null; }
}
reflect(HTMLOptionElement, { disabled: ['disabled', 'bool'] });
class HTMLOptGroupElement extends HTMLElement { }
reflect(HTMLOptGroupElement, { label: 'label', disabled: ['disabled', 'bool'] });
class HTMLButtonElement extends FormControl {
    get type() { const t = (this.getAttribute('type') || 'submit').toLowerCase(); return t === 'button' || t === 'reset' ? t : 'submit'; }
    set type(v) { this.setAttribute('type', v); }
}
reflect(HTMLButtonElement, { value: 'value', formAction: 'formaction', formMethod: 'formmethod', formNoValidate: ['formnovalidate', 'bool'], formTarget: 'formtarget' });
class HTMLFormElement extends HTMLElement {
    get elements() {
        const id = this.id, els = list(lx.query(this[N], selh('input,select,textarea,button,fieldset,output,object'), 1));
        if (id) for (const e of document.querySelectorAll('[form]')) if (e.getAttribute('form') === id && !els.includes(e)) els.push(e);
        for (const e of els) { const n = e.getAttribute('name') || e.id; if (n && !(n in els)) hide(els, n, e); }
        return els;
    }
    get length() { return this.elements.length; }
    get action() { const a = this.getAttribute('action'); return lx.resolve(a || ''); }
    set action(v) { this.setAttribute('action', v); }
    get method() { return (this.getAttribute('method') || 'get').toLowerCase() === 'post' ? 'post' : 'get'; }
    set method(v) { this.setAttribute('method', v); }
    submit() { lx.submit(this[N]); }
    requestSubmit(btn) {
        const ev = fire(this, 'submit', { bubbles: true, cancelable: true, submitter: btn || null }, SubmitEvent);
        if (!ev.defaultPrevented) lx.submit(this[N]);
    }
    reset() {
        if (!fire(this, 'reset', { bubbles: true, cancelable: true }).defaultPrevented)
            for (const e of this.elements) {
                if (e instanceof HTMLInputElement) { if (e.type === 'checkbox' || e.type === 'radio') e.checked = e.defaultChecked; else e.value = e.defaultValue; }
                else if (e instanceof HTMLTextAreaElement) e.value = e.defaultValue;
                else if (e instanceof HTMLSelectElement) e.selectedIndex = Math.max(0, e.options.findIndex(o => o.defaultSelected));
            }
    }
    checkValidity() { return true; }
    reportValidity() { return true; }
}
reflect(HTMLFormElement, { name: 'name', target: 'target', enctype: 'enctype', encoding: 'enctype', acceptCharset: 'accept-charset',
    noValidate: ['novalidate', 'bool'], autocomplete: 'autocomplete' });
class HTMLLabelElement extends HTMLElement {
    get control() {
        const f = this.htmlFor;
        if (f) return document.getElementById(f);
        return this.querySelector('input,select,textarea,button');
    }
    get form() { const c = this.control; return c ? c.form : null; }
}
reflect(HTMLLabelElement, { htmlFor: 'for' });
class HTMLFieldSetElement extends FormControl {
    get elements() { return list(lx.query(this[N], selh('input,select,textarea,button'), 1)); }
    get type() { return 'fieldset'; }
}
class HTMLOutputElement extends FormControl {
    get value() { return this.textContent; }
    set value(v) { this.textContent = v; }
    get type() { return 'output'; }
}
class HTMLTemplateElement extends HTMLElement {
    get innerHTML() { return this.content.innerHTML; }
    set innerHTML(v) { setHTML(this.content, v); }
    get content() {
        if (!this._c) hide(this, '_c', new DocumentFragment());
        for (let k; (k = lx.first(this[N])); ) lx.insert(this._c[N], k, 0);
        return this._c;
    }
}
class CanvasRenderingContext2D {
    constructor(c) { this.canvas = c; Object.assign(this, { fillStyle: '#000', strokeStyle: '#000', lineWidth: 1, font: '10px sans-serif', globalAlpha: 1,
        textAlign: 'start', textBaseline: 'alphabetic', lineCap: 'butt', lineJoin: 'miter', shadowBlur: 0, shadowColor: 'transparent',
        globalCompositeOperation: 'source-over', imageSmoothingEnabled: true }); }
    measureText(t) { const w = String(t).length * 6; return { width: w, actualBoundingBoxAscent: 8, actualBoundingBoxDescent: 2, actualBoundingBoxLeft: 0, actualBoundingBoxRight: w, fontBoundingBoxAscent: 8, fontBoundingBoxDescent: 2 }; }
    getImageData(x, y, w, h) { return { width: w, height: h, data: new Uint8ClampedArray(Math.max(0, w * h * 4)) }; }
    createImageData(w, h) { return this.getImageData(0, 0, w, h); }
    createLinearGradient() { return { addColorStop() { } }; }
    createRadialGradient() { return { addColorStop() { } }; }
    createConicGradient() { return { addColorStop() { } }; }
    createPattern() { return {}; }
    getTransform() { return { a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 }; }
    isPointInPath() { return false; }
    getLineDash() { return []; }
    getContextAttributes() { return {}; }
}
for (const k of ['save', 'restore', 'scale', 'rotate', 'translate', 'transform', 'setTransform', 'resetTransform', 'clearRect', 'fillRect', 'strokeRect',
    'beginPath', 'closePath', 'moveTo', 'lineTo', 'bezierCurveTo', 'quadraticCurveTo', 'arc', 'arcTo', 'ellipse', 'rect', 'roundRect', 'fill', 'stroke',
    'clip', 'fillText', 'strokeText', 'drawImage', 'putImageData', 'setLineDash', 'drawFocusIfNeeded', 'reset'])
    CanvasRenderingContext2D.prototype[k] = function () { };
class HTMLCanvasElement extends HTMLElement {
    get width() { return +this.getAttribute('width') || 300; }
    set width(v) { this.setAttribute('width', v); }
    get height() { return +this.getAttribute('height') || 150; }
    set height(v) { this.setAttribute('height', v); }
    getContext(t) { return t === '2d' ? this._ctx || (hide(this, '_ctx', new CanvasRenderingContext2D(this)), this._ctx) : null; }
    toDataURL() { return 'data:,'; }
    toBlob(cb) { setTimeout(() => cb(null), 0); }
    captureStream() { return null; }
    transferControlToOffscreen() { throw new DOMException('Not supported', 'NotSupportedError'); }
}
class HTMLIFrameElement extends HTMLElement {
    get contentWindow() { return null; }
    get contentDocument() { return null; }
}
reflect(HTMLIFrameElement, { src: ['src', 'url'], srcdoc: 'srcdoc', name: 'name', allow: 'allow', loading: 'loading', width: 'width', height: 'height',
    referrerPolicy: 'referrerpolicy', allowFullscreen: ['allowfullscreen', 'bool'] });
class HTMLMediaElement extends HTMLElement {
    get paused() { return true; }
    get currentTime() { return 0; }
    set currentTime(v) { }
    get duration() { return NaN; }
    get ended() { return false; }
    get readyState() { return 0; }
    get networkState() { return 3; }
    get buffered() { return { length: 0, start() { return 0; }, end() { return 0; } }; }
    get volume() { return 1; }
    set volume(v) { }
    get muted() { return this.hasAttribute('muted'); }
    set muted(v) { this.toggleAttribute('muted', !!v); }
    get playbackRate() { return 1; }
    set playbackRate(v) { }
    play() { return Promise.reject(new DOMException('Playback is not supported in LexOS Web.', 'NotSupportedError')); }
    pause() { }
    load() { }
    canPlayType() { return ''; }
    get error() { return null; }
    get textTracks() { return []; }
}
reflect(HTMLMediaElement, { src: ['src', 'url'], autoplay: ['autoplay', 'bool'], loop: ['loop', 'bool'], controls: ['controls', 'bool'],
    preload: 'preload', crossOrigin: 'crossorigin', poster: ['poster', 'url'], playsInline: ['playsinline', 'bool'] });
class HTMLVideoElement extends HTMLMediaElement { get videoWidth() { return 0; } get videoHeight() { return 0; } }
class HTMLAudioElement extends HTMLMediaElement { }
class HTMLDialogElement extends HTMLElement {
    get open() { return this.hasAttribute('open'); }
    set open(v) { this.toggleAttribute('open', !!v); }
    show() { this.open = true; }
    showModal() { this.open = true; }
    close(rv) { if (!this.open) return; this.open = false; if (rv !== undefined) this.returnValue = String(rv); fire(this, 'close'); }
}
class HTMLDetailsElement extends HTMLElement {
    get open() { return this.hasAttribute('open'); }
    set open(v) { this.toggleAttribute('open', !!v); }
}
class HTMLTableElement extends HTMLElement {
    get rows() { return list(lx.query(this[N], -1, 1, 'tr')); }
    get tBodies() { return list(lx.kids(this[N], 1).filter(k => lx.atom(lx.tag(k)) === 'tbody')); }
    get tHead() { return this.querySelector(':scope > thead'); }
    get tFoot() { return this.querySelector(':scope > tfoot'); }
    get caption() { return this.querySelector(':scope > caption'); }
    insertRow(i) { const r = document.createElement('tr'), b = this.tBodies[0] || this, rows = b.querySelectorAll(':scope > tr'); b.insertBefore(r, i === undefined || i < 0 ? null : rows[i] || null); return r; }
    deleteRow(i) { const r = this.rows[i < 0 ? this.rows.length - 1 : i]; if (r) r.remove(); }
    createTBody() { const b = document.createElement('tbody'); this.appendChild(b); return b; }
}
class HTMLTableSectionElement extends HTMLElement {
    get rows() { return list(lx.kids(this[N], 1).filter(k => lx.atom(lx.tag(k)) === 'tr')); }
    insertRow(i) { const r = document.createElement('tr'); this.insertBefore(r, i === undefined || i < 0 ? null : this.rows[i] || null); return r; }
    deleteRow(i) { const r = this.rows[i]; if (r) r.remove(); }
}
class HTMLTableRowElement extends HTMLElement {
    get cells() { return list(lx.kids(this[N], 1).filter(k => /^t[dh]$/.test(lx.atom(lx.tag(k))))); }
    get rowIndex() { const t = this.closest('table'); return t ? t.rows.indexOf(this) : -1; }
    get sectionRowIndex() { const p = this.parentElement; return p ? p.children.indexOf(this) : -1; }
    insertCell(i) { const c = document.createElement('td'); this.insertBefore(c, i === undefined || i < 0 ? null : this.cells[i] || null); return c; }
    deleteCell(i) { const c = this.cells[i]; if (c) c.remove(); }
}
class HTMLTableCellElement extends HTMLElement {
    get cellIndex() { const r = this.parentElement; return r && r.cells ? r.cells.indexOf(this) : -1; }
}
reflect(HTMLTableCellElement, { colSpan: ['colspan', 'num', 1], rowSpan: ['rowspan', 'num', 1], headers: 'headers', scope: 'scope', abbr: 'abbr' });
class HTMLMetaElement extends HTMLElement { }
reflect(HTMLMetaElement, { name: 'name', content: 'content', httpEquiv: 'http-equiv', charset: 'charset', media: 'media' });
class HTMLTitleElement extends HTMLElement { get text() { return this.textContent; } set text(v) { this.textContent = v; } }
class HTMLBaseElement extends HTMLElement { }
reflect(HTMLBaseElement, { href: ['href', 'url'], target: 'target' });
class HTMLProgressElement extends HTMLElement {
    get value() { return parseFloat(this.getAttribute('value')) || 0; }
    set value(v) { this.setAttribute('value', v); }
    get max() { return parseFloat(this.getAttribute('max')) || 1; }
    set max(v) { this.setAttribute('max', v); }
    get position() { return this.value / this.max; }
}
class HTMLMeterElement extends HTMLProgressElement { }
class HTMLSlotElement extends HTMLElement { assignedNodes() { return []; } assignedElements() { return []; } assign() { } }
reflect(HTMLSlotElement, { name: 'name' });
class HTMLSourceElement extends HTMLElement { }
reflect(HTMLSourceElement, { src: ['src', 'url'], srcset: 'srcset', type: 'type', media: 'media', sizes: 'sizes' });
class HTMLObjectElement extends HTMLElement { get contentDocument() { return null; } }
reflect(HTMLObjectElement, { data: ['data', 'url'], type: 'type', name: 'name', width: 'width', height: 'height' });
class HTMLEmbedElement extends HTMLElement { }
reflect(HTMLEmbedElement, { src: ['src', 'url'], type: 'type', width: 'width', height: 'height' });
class HTMLLIElement extends HTMLElement { }
reflect(HTMLLIElement, { value: ['value', 'num', 0], type: 'type' });
class HTMLOListElement extends HTMLElement { }
reflect(HTMLOListElement, { start: ['start', 'num', 1], reversed: ['reversed', 'bool'], type: 'type' });
class HTMLDataElement extends HTMLElement { }
reflect(HTMLDataElement, { value: 'value' });
class HTMLTimeElement extends HTMLElement { }
reflect(HTMLTimeElement, { dateTime: 'datetime' });
class HTMLQuoteElement extends HTMLElement { }
reflect(HTMLQuoteElement, { cite: ['cite', 'url'] });
class HTMLModElement extends HTMLQuoteElement { }
const simple = {};
for (const n of ['Html', 'Head', 'Body', 'Div', 'Span', 'Paragraph', 'Heading', 'UList', 'DList', 'Pre', 'BR', 'HR', 'Unknown', 'Legend',
    'Picture', 'Menu', 'Directory', 'Font', 'Frame', 'FrameSet', 'Map', 'Param', 'Track', 'TableCaption', 'TableCol', 'DataList', 'Marquee'])
    simple[n] = class extends HTMLElement { };
for (const n of Object.keys(simple)) Object.defineProperty(simple[n], 'name', { value: 'HTML' + n + 'Element' });
class SVGElement extends Element {
    get dataset() { return Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'dataset').get.call(this); }
    get style() { return Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'style').get.call(this); }
    get ownerSVGElement() { return this.closest('svg'); }
    get viewportElement() { return this.ownerSVGElement; }
    focus() { }
    blur() { }
    getBBox() { const r = lx.rect(this[N]); return new DOMRect(0, 0, r[2], r[3]); }
    getCTM() { return null; }
    getScreenCTM() { return null; }
}
handlers(SVGElement.prototype, EVENTS);
class SVGSVGElement extends SVGElement { createSVGPoint() { return { x: 0, y: 0, matrixTransform() { return this; } }; } }
class SVGGraphicsElement extends SVGElement { }
const TAGS = {
    a: HTMLAnchorElement, area: HTMLAreaElement, img: HTMLImageElement, script: HTMLScriptElement, style: HTMLStyleElement, link: HTMLLinkElement,
    input: HTMLInputElement, textarea: HTMLTextAreaElement, select: HTMLSelectElement, option: HTMLOptionElement, optgroup: HTMLOptGroupElement,
    button: HTMLButtonElement, form: HTMLFormElement, label: HTMLLabelElement, fieldset: HTMLFieldSetElement, output: HTMLOutputElement,
    template: HTMLTemplateElement, canvas: HTMLCanvasElement, iframe: HTMLIFrameElement, video: HTMLVideoElement, audio: HTMLAudioElement,
    dialog: HTMLDialogElement, details: HTMLDetailsElement, table: HTMLTableElement, thead: HTMLTableSectionElement, tbody: HTMLTableSectionElement,
    tfoot: HTMLTableSectionElement, tr: HTMLTableRowElement, td: HTMLTableCellElement, th: HTMLTableCellElement, meta: HTMLMetaElement,
    title: HTMLTitleElement, base: HTMLBaseElement, progress: HTMLProgressElement, meter: HTMLMeterElement, slot: HTMLSlotElement,
    source: HTMLSourceElement, object: HTMLObjectElement, embed: HTMLEmbedElement, li: HTMLLIElement, ol: HTMLOListElement, data: HTMLDataElement,
    time: HTMLTimeElement, q: HTMLQuoteElement, blockquote: HTMLQuoteElement, del: HTMLModElement, ins: HTMLModElement,
    html: simple.Html, head: simple.Head, body: simple.Body, div: simple.Div, span: simple.Span, p: simple.Paragraph, ul: simple.UList,
    dl: simple.DList, pre: simple.Pre, br: simple.BR, hr: simple.HR, legend: simple.Legend, picture: simple.Picture, menu: simple.Menu,
    font: simple.Font, map: simple.Map, param: simple.Param, track: simple.Track, caption: simple.TableCaption, col: simple.TableCol,
    colgroup: simple.TableCol, datalist: simple.DataList, marquee: simple.Marquee, frame: simple.Frame, frameset: simple.FrameSet,
    svg: SVGSVGElement, path: SVGGraphicsElement, g: SVGGraphicsElement, circle: SVGGraphicsElement, rect: SVGGraphicsElement,
    line: SVGGraphicsElement, polygon: SVGGraphicsElement, polyline: SVGGraphicsElement, use: SVGGraphicsElement, text: SVGGraphicsElement,
};
for (const h of ['h1', 'h2', 'h3', 'h4', 'h5', 'h6']) TAGS[h] = simple.Heading;

/* custom elements */
const ceDefs = new Map(), ceTags = new Map(), ceWait = new Map();
let upgrading = 0;
function upgrade(id, C) {
    const old = nodes[id];
    let o;
    upgrading = id;
    try { o = new C(); }
    catch (e) { report(e); upgrading = 0; o = Object.create(C.prototype); o[N] = id; nodes[id] = o; }
    upgrading = 0;
    if (old && old !== o && old[STY]) hide(o, STY, old[STY]);
    const obs = C.observedAttributes;
    if (obs && typeof o.attributeChangedCallback === 'function')
        for (const a of Array.from(obs)) { const v = lx.getattr(id, a); if (v !== null) safe(o.attributeChangedCallback, [a, null, v], o); }
    return o;
}
const customElements = {
    define(name, C) {
        name = String(name).toLowerCase();
        if (ceDefs.has(name)) throw new DOMException(`'${name}' has already been defined as a custom element`, 'NotSupportedError');
        ceDefs.set(name, C);
        ceTags.set(C, name);
        for (const id of lx.query(docIds[0], -1, 1, name)) {
            const o = upgrade(id, C);
            if (typeof o.connectedCallback === 'function') safe(o.connectedCallback, [], o);
        }
        const w = ceWait.get(name);
        if (w) { ceWait.delete(name); w.resolve(C); }
    },
    get(name) { return ceDefs.get(String(name).toLowerCase()); },
    getName(C) { return ceTags.get(C) || null; },
    whenDefined(name) {
        name = String(name).toLowerCase();
        if (ceDefs.has(name)) return Promise.resolve(ceDefs.get(name));
        let w = ceWait.get(name);
        if (!w) { let r; const p = new Promise(x => { r = x; }); w = { p, resolve: r }; ceWait.set(name, w); }
        return w.p;
    },
    upgrade(root) { },
};

/* ================================================================
 * the document
 * ================================================================ */
class Document extends Node {
    constructor() { super(); const id = lx.newfrag(9); this[N] = id; nodes[id] = this; }
    get documentElement() { return this === document ? W(docIds[1]) : this.firstElementChild; }
    get head() { return this === document ? W(docIds[2]) : this.querySelector('head'); }
    get body() { return this === document ? W(docIds[3]) : this.querySelector('body'); }
    set body(b) { const old = this.body; if (old && b && old !== b) old.replaceWith(b); }
    get title() { const t = this.querySelector('title'); return t ? t.textContent.replace(/\s+/g, ' ').trim() : ''; }
    set title(v) {
        let t = this.querySelector('title');
        if (!t) { t = this.createElement('title'); this.head.appendChild(t); }
        t.textContent = v;
        if (this === document) lx.title(sv(v));
    }
    get readyState() { return readyState; }
    get currentScript() { return curScript; }
    get URL() { return lx.url(); }
    get documentURI() { return lx.url(); }
    get baseURI() { return lx.base(); }
    get location() { return this === document ? location : null; }
    set location(v) { location.href = v; }
    get referrer() { return ''; }
    get domain() { return location.hostname; }
    set domain(v) { }
    get cookie() { return lx.cookie(); }
    set cookie(v) { lx.setcookie(String(v)); }
    get lastModified() { return new Date().toLocaleString(); }
    get characterSet() { return 'UTF-8'; }
    get charset() { return 'UTF-8'; }
    get inputEncoding() { return 'UTF-8'; }
    get contentType() { return 'text/html'; }
    get compatMode() { return 'CSS1Compat'; }
    get designMode() { return 'off'; }
    set designMode(v) { }
    get dir() { return this.documentElement ? this.documentElement.dir : ''; }
    set dir(v) { if (this.documentElement) this.documentElement.dir = v; }
    get doctype() { return { name: 'html', publicId: '', systemId: '', nodeType: 10, nodeName: 'html' }; }
    get defaultView() { return this === document ? G : null; }
    get activeElement() { return W(lx.active()) || this.body; }
    get hidden() { return false; }
    get visibilityState() { return 'visible'; }
    get fullscreenElement() { return null; }
    get fullscreenEnabled() { return false; }
    get pointerLockElement() { return null; }
    get scrollingElement() { return this.documentElement; }
    get implementation() { return { createHTMLDocument: t => newDocument('<title>' + sv(t) + '</title>'), hasFeature: () => true,
        createDocument: () => newDocument(''), createDocumentType: (n) => ({ name: n, nodeType: 10 }) }; }
    get forms() { return named(this.getElementsByTagName('form')); }
    get images() { return this.getElementsByTagName('img'); }
    get links() { return this.querySelectorAll('a[href],area[href]'); }
    get anchors() { return this.querySelectorAll('a[name]'); }
    get scripts() { return this.getElementsByTagName('script'); }
    get embeds() { return this.getElementsByTagName('embed'); }
    get plugins() { return this.embeds; }
    get styleSheets() { return list(lx.query(this[N], selh('style,link[rel~=stylesheet]'), 1)).map(e => e.sheet).filter(Boolean); }
    get fonts() { return fonts; }
    get timeline() { return { currentTime: lx.now() }; }
    get adoptedStyleSheets() { return []; }
    set adoptedStyleSheets(v) { for (const s of v || []) if (s && s._text) lx.addcss(s._text, null); }
    getElementById(id) {
        if (this === document) return W(lx.byid(String(id)));
        return this.querySelector('#' + CSS.escape(String(id)));
    }
    getElementsByName(n) { return list(lx.query(this[N], -3, 1, String(n))); }
    createElement(t) {
        t = String(t).toLowerCase();
        if (!/^[a-z][^\s<>\/=]*$/.test(t)) throw new DOMException(`The tag name provided ('${t}') is not a valid name.`, 'InvalidCharacterError');
        const C = ceDefs.get(t);
        if (C) return upgrade(lx.create(t), C);
        return W(lx.create(t));
    }
    createElementNS(ns, t) { return this.createElement(String(t).replace(/^.*:/, '')); }
    createTextNode(t) { return new Text(t); }
    createComment(t) { return new Comment(t); }
    createCDATASection(t) { return new Text(t); }
    createDocumentFragment() { return new DocumentFragment(); }
    createProcessingInstruction() { return new Comment(''); }
    createAttribute(n) { return new Attr(String(n).toLowerCase(), '', null); }
    createEvent(k) {
        const C = { mouseevent: MouseEvent, mouseevents: MouseEvent, keyboardevent: KeyboardEvent, keyboardevents: KeyboardEvent,
            uievent: UIEvent, uievents: UIEvent, customevent: CustomEvent, focusevent: FocusEvent, htmlevents: Event }[String(k).toLowerCase()] || Event;
        return new C('');
    }
    createRange() { return new Range(); }
    createTreeWalker(root, what, filter) { return new TreeWalker(root, what, filter); }
    createNodeIterator(root, what, filter) { return new TreeWalker(root, what, filter); }
    importNode(n, deep) { return n.cloneNode(!!deep); }
    adoptNode(n) { if (n.parentNode) n.remove(); return n; }
    elementFromPoint(x, y) { return W(lx.hit(x | 0, (y | 0) + lx.view()[2])); }
    elementsFromPoint(x, y) { const r = []; for (let e = this.elementFromPoint(x, y); e; e = e.parentElement) r.push(e); return r; }
    caretRangeFromPoint() { return null; }
    getSelection() { return selection; }
    hasFocus() { return true; }
    execCommand() { return false; }
    queryCommandSupported() { return false; }
    queryCommandEnabled() { return false; }
    queryCommandState() { return false; }
    open() { return this; }
    close() { }
    write(...a) {
        const html = a.join('');
        const f = lx.parse(html, 1), ids = kidIds(f);
        const cs = curScript;
        if (readyState === 'loading' && cs && cs.parentNode) {
            lx.insert(cs.parentNode[N], f, lx.next(cs[N]));
            came(cs.parentNode, ids, true);
        } else {
            lx.insert(docIds[3], f, 0);
            came(this.body, ids, false);
        }
    }
    writeln(...a) { this.write(...a, '\n'); }
    exitFullscreen() { return Promise.resolve(); }
    exitPointerLock() { }
    startViewTransition(f) { const r = Promise.resolve(f && f()); return { finished: r, ready: r, updateCallbackDone: r, skipTransition() { } }; }
}
mixin(Document, parentNode);
mixin(DocumentFragment, parentNode);
handlers(Document.prototype, EVENTS.concat(['readystatechange', 'visibilitychange', 'DOMContentLoaded', 'selectionchange', 'pointerlockchange', 'fullscreenchange']));
function named(l) { for (const e of l) { const n = e.getAttribute('name') || e.id; if (n && !(n in l)) hide(l, n, e); } return l; }
function newDocument(html) {
    const d = new Document();
    const h = lx.create('html'), hd = lx.create('head'), b = lx.create('body');
    lx.insert(d[N], h, 0); lx.insert(h, hd, 0); lx.insert(h, b, 0);
    const f = lx.parse(sv(html).replace(/<!doctype[^>]*>/i, ''), 0);
    const heads = /^(title|meta|link|style|base)$/;
    for (const k of kidIds(f)) lx.insert(lx.type(k) === 1 && heads.test(lx.atom(lx.tag(k))) ? hd : b, k, 0);
    for (const k of kidIds(b)) {                         // (<html><head>..</head><body>..</body>: unwrapped)
        const t = lx.type(k) === 1 ? lx.atom(lx.tag(k)) : '';
        if (t === 'head') { for (const c of kidIds(k)) lx.insert(hd, c, 0); lx.remove(k); }
        else if (t === 'body' || t === 'html') { for (const c of kidIds(k)) lx.insert(b, c, k); lx.remove(k); }
    }
    return d;
}

class Range {
    constructor() { this.startContainer = this.endContainer = this.commonAncestorContainer = document; this.startOffset = this.endOffset = 0; this.collapsed = true; }
    setStart(n, o) { this.startContainer = n; this.startOffset = o; this.commonAncestorContainer = n; }
    setEnd(n, o) { this.endContainer = n; this.endOffset = o; this.collapsed = false; }
    setStartBefore(n) { this.setStart(n.parentNode, 0); }
    setStartAfter(n) { this.setStart(n.parentNode, 0); }
    setEndBefore(n) { this.setEnd(n.parentNode, 0); }
    setEndAfter(n) { this.setEnd(n.parentNode, 0); }
    selectNode(n) { this.setStart(n.parentNode, 0); this.setEnd(n.parentNode, 0); }
    selectNodeContents(n) { this.setStart(n, 0); this.setEnd(n, n.childNodes.length); }
    collapse() { this.collapsed = true; }
    cloneRange() { return Object.assign(new Range(), this); }
    cloneContents() { return new DocumentFragment(); }
    extractContents() { return new DocumentFragment(); }
    deleteContents() { }
    insertNode(n) { const c = this.startContainer; if (c && c.nodeType === 1) c.insertBefore(n, c.childNodes[this.startOffset] || null); }
    surroundContents(n) { this.insertNode(n); }
    createContextualFragment(html) { return W(lx.parse(sv(html), 1)); }
    getBoundingClientRect() { return this.startContainer && this.startContainer.getBoundingClientRect ? this.startContainer.getBoundingClientRect() : new DOMRect(); }
    getClientRects() { return []; }
    toString() { return ''; }
    detach() { }
    compareBoundaryPoints() { return 0; }
}
const selection = { rangeCount: 0, isCollapsed: true, type: 'None', anchorNode: null, focusNode: null, anchorOffset: 0, focusOffset: 0,
    removeAllRanges() { }, addRange() { }, getRangeAt() { return new Range(); }, collapse() { }, collapseToEnd() { }, collapseToStart() { },
    selectAllChildren() { }, extend() { }, deleteFromDocument() { }, containsNode() { return false; }, empty() { }, setBaseAndExtent() { },
    toString() { return ''; } };
const NodeFilter = { FILTER_ACCEPT: 1, FILTER_REJECT: 2, FILTER_SKIP: 3, SHOW_ALL: 0xFFFFFFFF, SHOW_ELEMENT: 1, SHOW_ATTRIBUTE: 2, SHOW_TEXT: 4,
    SHOW_CDATA_SECTION: 8, SHOW_PROCESSING_INSTRUCTION: 64, SHOW_COMMENT: 128, SHOW_DOCUMENT: 256, SHOW_DOCUMENT_TYPE: 512, SHOW_DOCUMENT_FRAGMENT: 1024 };
class TreeWalker {
    constructor(root, what, filter) { this.root = root; this.whatToShow = what === undefined ? 0xFFFFFFFF : what >>> 0; this.filter = filter || null; this.currentNode = root; }
    _ok(n) {
        if (!(this.whatToShow & (1 << (n.nodeType - 1)))) return 3;
        const f = this.filter;
        if (!f) return 1;
        return (typeof f === 'function' ? f(n) : f.acceptNode(n)) || 1;
    }
    _next(id) {
        if (lx.first(id)) return lx.first(id);
        for (let n = id; n && n !== this.root[N]; n = lx.parent(n)) if (lx.next(n)) return lx.next(n);
        return 0;
    }
    nextNode() {
        for (let id = this._next(this.currentNode[N]); id; id = this._next(id)) {
            const n = W(id);
            if (this._ok(n) === 1) { this.currentNode = n; return n; }
        }
        return null;
    }
    previousNode() {
        let id = this.currentNode[N];
        while (id && id !== this.root[N]) {
            let p = lx.prev(id);
            if (p) { while (lx.last(p)) p = lx.last(p); id = p; } else id = lx.parent(id);
            if (!id) break;
            const n = W(id);
            if (this._ok(n) === 1) { this.currentNode = n; return n; }
            if (id === this.root[N]) break;
        }
        return null;
    }
    parentNode() { const p = this.currentNode.parentNode; if (p && p !== this.root && this.root.contains(p)) { this.currentNode = p; return p; } return null; }
    firstChild() { for (let c = this.currentNode.firstChild; c; c = c.nextSibling) if (this._ok(c) === 1) { this.currentNode = c; return c; } return null; }
    lastChild() { for (let c = this.currentNode.lastChild; c; c = c.previousSibling) if (this._ok(c) === 1) { this.currentNode = c; return c; } return null; }
    nextSibling() { for (let c = this.currentNode.nextSibling; c; c = c.nextSibling) if (this._ok(c) === 1) { this.currentNode = c; return c; } return null; }
    previousSibling() { for (let c = this.currentNode.previousSibling; c; c = c.previousSibling) if (this._ok(c) === 1) { this.currentNode = c; return c; } return null; }
    get referenceNode() { return this.currentNode; }
    detach() { }
}
class DOMRectReadOnly {
    constructor(x, y, w, h) { this.x = x || 0; this.y = y || 0; this.width = w || 0; this.height = h || 0; }
    get top() { return Math.min(this.y, this.y + this.height); }
    get left() { return Math.min(this.x, this.x + this.width); }
    get right() { return Math.max(this.x, this.x + this.width); }
    get bottom() { return Math.max(this.y, this.y + this.height); }
    toJSON() { const { x, y, width, height, top, left, right, bottom } = this; return { x, y, width, height, top, left, right, bottom }; }
    static fromRect(r) { r = r || {}; return new this(r.x, r.y, r.width, r.height); }
}
class DOMRect extends DOMRectReadOnly { }
class DOMPoint { constructor(x, y, z, w) { this.x = x || 0; this.y = y || 0; this.z = z || 0; this.w = w === undefined ? 1 : w; } matrixTransform() { return this; } }
class DOMMatrix {
    constructor() { Object.assign(this, { a: 1, b: 0, c: 0, d: 1, e: 0, f: 0, m41: 0, m42: 0, is2D: true, isIdentity: true }); }
    translate() { return new DOMMatrix(); } scale() { return new DOMMatrix(); } rotate() { return new DOMMatrix(); } multiply() { return new DOMMatrix(); }
    inverse() { return new DOMMatrix(); } transformPoint(p) { return new DOMPoint(p && p.x, p && p.y); } toString() { return 'matrix(1, 0, 0, 1, 0, 0)'; }
}

/* ================================================================
 * the window: the page's address, history, the browser, the screen
 * ================================================================ */
function parseURL(s) {
    const m = /^([a-zA-Z][a-zA-Z0-9+.-]*:)(?:\/\/(?:([^:@\/?#]*)(?::([^@\/?#]*))?@)?(\[[^\]]*\]|[^:\/?#]*)(?::(\d*))?)?([^?#]*)(\?[^#]*)?(#.*)?$/.exec(s);
    if (!m) return null;
    return { protocol: m[1].toLowerCase(), username: m[2] || '', password: m[3] || '', hostname: (m[4] || '').toLowerCase(), port: m[5] || '',
        pathname: m[6] || (m[4] !== undefined ? '/' : ''), search: m[7] && m[7] !== '?' ? m[7] : '', hash: m[8] && m[8] !== '#' ? m[8] : '' };
}
const DEFPORT = { 'http:': '80', 'https:': '443', 'ws:': '80', 'wss:': '443', 'ftp:': '21' };
class URLSearchParams {
    constructor(init) {
        hide(this, '_l', []);
        hide(this, '_u', null);
        if (init == null) return;
        if (typeof init === 'object') {
            if (init instanceof URLSearchParams) this._l = init._l.map(p => p.slice());
            else if (Symbol.iterator in init) for (const [k, v] of init) this._l.push([String(k), String(v)]);
            else for (const k of Object.keys(init)) this._l.push([k, String(init[k])]);
        } else this._parse(String(init));
    }
    _parse(s) {
        this._l = [];
        if (s[0] === '?') s = s.slice(1);
        for (const part of s.split('&')) {
            if (!part) continue;
            const i = part.indexOf('='), k = i < 0 ? part : part.slice(0, i), v = i < 0 ? '' : part.slice(i + 1);
            const d = x => { try { return decodeURIComponent(x.replace(/\+/g, ' ')); } catch (e) { return x; } };
            this._l.push([d(k), d(v)]);
        }
    }
    _upd() { if (this._u) { const s = this.toString(); this._u._search = s ? '?' + s : ''; } }
    get size() { return this._l.length; }
    append(k, v) { this._l.push([String(k), String(v)]); this._upd(); }
    delete(k, v) { this._l = this._l.filter(p => p[0] !== String(k) || (v !== undefined && p[1] !== String(v))); this._upd(); }
    get(k) { const p = this._l.find(p => p[0] === String(k)); return p ? p[1] : null; }
    getAll(k) { return this._l.filter(p => p[0] === String(k)).map(p => p[1]); }
    has(k, v) { return this._l.some(p => p[0] === String(k) && (v === undefined || p[1] === String(v))); }
    set(k, v) {
        k = String(k);
        const i = this._l.findIndex(p => p[0] === k);
        if (i < 0) this._l.push([k, String(v)]);
        else { this._l[i][1] = String(v); this._l = this._l.filter((p, j) => j <= i || p[0] !== k); }
        this._upd();
    }
    sort() { this._l.sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0); this._upd(); }
    forEach(f, self) { for (const [k, v] of this._l) f.call(self, v, k, this); }
    entries() { return this._l.map(p => [p[0], p[1]])[Symbol.iterator](); }
    keys() { return this._l.map(p => p[0])[Symbol.iterator](); }
    values() { return this._l.map(p => p[1])[Symbol.iterator](); }
    [Symbol.iterator]() { return this.entries(); }
    toString() {
        const e = s => encodeURIComponent(s).replace(/%20/g, '+').replace(/[!'()~]/g, c => '%' + c.charCodeAt(0).toString(16).toUpperCase());
        return this._l.map(([k, v]) => e(k) + '=' + e(v)).join('&');
    }
}
const blobURLs = new Map();
let blobN = 0;
class URL {
    constructor(u, base) {
        u = String(u);
        let p = parseURL(u);
        if (!p || (base !== undefined && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(u))) {
            if (base === undefined) { if (!p) throw new TypeError(`Failed to construct 'URL': Invalid URL`); }
            else {
                const b = String(base instanceof URL ? base.href : base);
                if (!parseURL(b)) throw new TypeError(`Failed to construct 'URL': Invalid base URL`);
                p = parseURL(lx.resolve(u, b));
                if (!p) throw new TypeError(`Failed to construct 'URL': Invalid URL`);
            }
        }
        if (p.port === DEFPORT[p.protocol]) p.port = '';
        hide(this, '_p', p);
        hide(this, '_search', p.search);
        hide(this, '_sp', null);
    }
    get protocol() { return this._p.protocol; }
    set protocol(v) { this._p.protocol = String(v).replace(/:?$/, ':').toLowerCase(); }
    get username() { return this._p.username; }
    set username(v) { this._p.username = String(v); }
    get password() { return this._p.password; }
    set password(v) { this._p.password = String(v); }
    get hostname() { return this._p.hostname; }
    set hostname(v) { this._p.hostname = String(v).toLowerCase(); }
    get port() { return this._p.port; }
    set port(v) { v = String(v); this._p.port = v === DEFPORT[this._p.protocol] ? '' : v; }
    get host() { return this._p.hostname + (this._p.port ? ':' + this._p.port : ''); }
    set host(v) { const [h, pt] = String(v).split(':'); this.hostname = h; this.port = pt || ''; }
    get origin() { return /^(https?|wss?|ftp):$/.test(this._p.protocol) ? this._p.protocol + '//' + this.host : 'null'; }
    get pathname() { return this._p.pathname; }
    set pathname(v) { v = String(v); this._p.pathname = v[0] === '/' ? v : '/' + v; }
    get search() { return this._search; }
    set search(v) { v = String(v); this._search = v && v !== '?' ? (v[0] === '?' ? v : '?' + v) : ''; if (this._sp) this._sp._parse(this._search); }
    get searchParams() { if (!this._sp) { hide(this, '_sp', new URLSearchParams(this._search)); this._sp._u = this; } return this._sp; }
    get hash() { return this._p.hash; }
    set hash(v) { v = String(v); this._p.hash = v && v !== '#' ? (v[0] === '#' ? v : '#' + v) : ''; }
    get href() {
        const p = this._p, auth = p.username ? p.username + (p.password ? ':' + p.password : '') + '@' : '';
        const special = /^(https?|wss?|ftp|file):$/.test(p.protocol);
        return p.protocol + (special || p.hostname ? '//' + auth + this.host : '') + p.pathname + this._search + p.hash;
    }
    set href(v) { const p = parseURL(String(v)); if (!p) throw new TypeError('Invalid URL'); this._p = p; this._search = p.search; if (this._sp) this._sp._parse(p.search); }
    toString() { return this.href; }
    toJSON() { return this.href; }
    static canParse(u, b) { try { new URL(u, b); return true; } catch (e) { return false; } }
    static parse(u, b) { try { return new URL(u, b); } catch (e) { return null; } }
    static createObjectURL(b) { const u = 'blob:' + location.origin + '/' + (++blobN); blobURLs.set(u, b); return u; }
    static revokeObjectURL(u) { blobURLs.delete(u); }
}
const location = Object.create({
    get href() { return lx.url(); },
    set href(v) { lx.nav(String(v), 0); },
    assign(v) { lx.nav(String(v), 0); },
    replace(v) { lx.nav(String(v), 1); },
    reload() { lx.nav(lx.url(), 1); },
    toString() { return lx.url(); },
    get ancestorOrigins() { return []; },
});
for (const k of ['protocol', 'host', 'hostname', 'port', 'pathname', 'search', 'hash', 'origin']) {
    Object.defineProperty(Object.getPrototypeOf(location), k, {
        get() { try { return new URL(lx.url())[k]; } catch (e) { return ''; } },
        set(v) {
            if (k === 'origin') return;
            const u = new URL(lx.url());
            u[k] = v;
            lx.nav(u.href, 0);
        },
        enumerable: true, configurable: true,
    });
}
let histState = null, histLen = 1;
const history = {
    get length() { return histLen; },
    get state() { return histState; },
    scrollRestoration: 'auto',
    pushState(s, t, u) { histState = s === undefined ? null : s; histLen++; if (u != null) lx.pushurl(String(u)); },
    replaceState(s, t, u) { histState = s === undefined ? null : s; if (u != null) lx.pushurl(String(u)); },
    back() { lx.histgo(-1); },
    forward() { lx.histgo(1); },
    go(n) { if (n) lx.histgo(n); else location.reload(); },
};
const navigator = {
    userAgent: 'Mozilla/5.0 (LexOS; x86) AppleWebKit/537.36 (KHTML, like Gecko) LexOS-Web/2.0', appName: 'Netscape', appCodeName: 'Mozilla',
    appVersion: '5.0 (LexOS)', platform: 'LexOS', product: 'Gecko', productSub: '20030107', vendor: '', vendorSub: '', language: 'ru',
    languages: ['ru', 'en', 'es'], cookieEnabled: true, onLine: true, doNotTrack: '1', hardwareConcurrency: 1, maxTouchPoints: 0,
    deviceMemory: 0.25, webdriver: false, pdfViewerEnabled: false, plugins: [], mimeTypes: [],
    connection: { effectiveType: '3g', downlink: 1, rtt: 300, saveData: true, type: 'ethernet', addEventListener() { }, removeEventListener() { } },
    clipboard: { writeText(t) { lx.clip(sv(t)); return Promise.resolve(); }, readText() { return Promise.resolve(''); },
        write() { return Promise.resolve(); }, read() { return Promise.resolve([]); } },
    permissions: { query() { return Promise.resolve({ state: 'denied', onchange: null, addEventListener() { } }); } },
    storage: { estimate() { return Promise.resolve({ quota: 4 << 20, usage: 0 }); }, persist() { return Promise.resolve(false); } },
    sendBeacon() { return true; },
    vibrate() { return false; },
    javaEnabled() { return false; },
    registerProtocolHandler() { },
    getGamepads() { return []; },
};
const screen = { width: 800, height: 600, availWidth: 800, availHeight: 560, colorDepth: 32, pixelDepth: 32, availLeft: 0, availTop: 0,
    orientation: { type: 'landscape-primary', angle: 0, addEventListener() { }, removeEventListener() { }, lock() { return Promise.reject(new Error('no')); } } };

/* timers, animation frames */
const timers = new Map();
let timerN = 0, rafs = [], rafN = 0, lastFrame = -1000;
function setTimeout(fn, ms, ...args) {
    const id = ++timerN, at = lx.now() + Math.max(0, +ms || 0);
    timers.set(id, { id, fn, args, at, every: 0 });
    lx.due(at);
    return id;
}
function setInterval(fn, ms, ...args) {
    const id = ++timerN, every = Math.max(10, +ms || 0), at = lx.now() + every;
    timers.set(id, { id, fn, args, at, every });
    lx.due(at);
    return id;
}
function clearTimeout(id) { timers.delete(id); }
function requestAnimationFrame(fn) {
    const id = ++rafN;
    rafs.push({ id, fn });
    lx.due(Math.max(lx.now(), lastFrame + 33));
    return id;
}
function cancelAnimationFrame(id) { rafs = rafs.filter(r => r.id !== id); }

/* storage: localStorage per site (in /TMP/WEB), sessionStorage while the page is */
class Storage {
    constructor(d, save) { hide(this, '_d', d); hide(this, '_s', save); }
    get length() { return Object.keys(this._d).length; }
    key(i) { return Object.keys(this._d)[i] ?? null; }
    getItem(k) { k = String(k); return Object.prototype.hasOwnProperty.call(this._d, k) ? this._d[k] : null; }
    setItem(k, v) { this._d[String(k)] = String(v); this._s(); }
    removeItem(k) { delete this._d[String(k)]; this._s(); }
    clear() { for (const k of Object.keys(this._d)) delete this._d[k]; this._s(); }
}
const stProxy = {
    get(t, k, r) { if (typeof k !== 'string' || k in t) return Reflect.get(t, k, r); return t.getItem(k) ?? undefined; },
    set(t, k, v) { if (typeof k !== 'string' || k in t) t[k] = v; else t.setItem(k, v); return true; },
    deleteProperty(t, k) { t.removeItem(k); return true; },
    has(t, k) { return k in t || (typeof k === 'string' && t.getItem(k) !== null); },
    ownKeys(t) { return Object.keys(t._d); },
    getOwnPropertyDescriptor(t, k) { const v = t.getItem(k); return v === null ? undefined : { value: v, writable: true, enumerable: true, configurable: true }; },
};
let lsDirty = false, lsData = null;
function lsGet() {
    if (!lsData) { lsData = Object.create(null); try { const t = lx.lsload(); if (t) Object.assign(lsData, JSON.parse(t)); } catch (e) { } }
    return lsData;
}
let localStorage_ = null;
const sessionStorage_ = new Proxy(new Storage(Object.create(null), () => { }), stProxy);

/* ================================================================
 * fetching: fetch(), XMLHttpRequest (js.h's http: waits, the page with it)
 * ================================================================ */
let netQ = [];
function later(f) { netQ.push(f); lx.due(lx.now()); }
class Headers {
    constructor(init) {
        hide(this, '_m', new Map());
        if (!init) return;
        if (init instanceof Headers) init.forEach((v, k) => this.append(k, v));
        else if (Array.isArray(init)) for (const [k, v] of init) this.append(k, v);
        else for (const k of Object.keys(init)) this.append(k, init[k]);
    }
    append(k, v) { k = String(k).toLowerCase(); const o = this._m.get(k); this._m.set(k, o === undefined ? String(v) : o + ', ' + v); }
    set(k, v) { this._m.set(String(k).toLowerCase(), String(v)); }
    get(k) { const v = this._m.get(String(k).toLowerCase()); return v === undefined ? null : v; }
    has(k) { return this._m.has(String(k).toLowerCase()); }
    delete(k) { this._m.delete(String(k).toLowerCase()); }
    forEach(f, self) { for (const [k, v] of this._m) f.call(self, v, k, this); }
    entries() { return this._m.entries(); }
    keys() { return this._m.keys(); }
    values() { return this._m.values(); }
    getSetCookie() { return []; }
    [Symbol.iterator]() { return this._m.entries(); }
}
const te = s => { const out = []; for (const ch of s) { let c = ch.codePointAt(0);
    if (c < 0x80) out.push(c); else if (c < 0x800) out.push(0xC0 | c >> 6, 0x80 | c & 63);
    else if (c < 0x10000) out.push(0xE0 | c >> 12, 0x80 | c >> 6 & 63, 0x80 | c & 63);
    else out.push(0xF0 | c >> 18, 0x80 | c >> 12 & 63, 0x80 | c >> 6 & 63, 0x80 | c & 63); } return new Uint8Array(out); };
function td(b) {
    let s = '', i = 0;
    const n = b.length;
    while (i < n) {
        let c = b[i++];
        if (c >= 0x80) {
            let k = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : c >= 0xC0 ? 1 : 0;
            if (!k) { s += '\uFFFD'; continue; }
            c &= 0x3F >> k;
            while (k-- && i < n) c = c << 6 | (b[i++] & 63);
        }
        if (c > 0xFFFF) { c -= 0x10000; s += String.fromCharCode(0xD800 + (c >> 10), 0xDC00 + (c & 1023)); }
        else if (s.length < 8192) s += String.fromCharCode(c);
        else s += String.fromCharCode(c);
    }
    return s;
}
class TextEncoder {
    get encoding() { return 'utf-8'; }
    encode(s) { return te(sv(s === undefined ? '' : s)); }
    encodeInto(s, a) { const b = te(sv(s)); const n = Math.min(b.length, a.length); a.set(b.subarray(0, n)); return { read: s.length, written: n }; }
}
class TextDecoder {
    constructor(l) { this.encoding = (l || 'utf-8').toLowerCase(); this.fatal = false; this.ignoreBOM = false; }
    decode(b) {
        if (!b) return '';
        const u = b instanceof ArrayBuffer ? new Uint8Array(b) : new Uint8Array(b.buffer, b.byteOffset, b.byteLength);
        if (/^(latin1|iso-8859-1|ascii|us-ascii|windows-1252)$/.test(this.encoding)) { let s = ''; for (const c of u) s += String.fromCharCode(c); return s; }
        const s = td(u);
        return s.charCodeAt(0) === 0xFEFF ? s.slice(1) : s;
    }
}
class Blob {
    constructor(parts, opt) {
        const bufs = [];
        for (const p of parts || []) {
            if (p instanceof Blob) bufs.push(p._b);
            else if (p instanceof ArrayBuffer) bufs.push(new Uint8Array(p));
            else if (ArrayBuffer.isView(p)) bufs.push(new Uint8Array(p.buffer, p.byteOffset, p.byteLength));
            else bufs.push(te(String(p)));
        }
        const n = bufs.reduce((a, b) => a + b.length, 0), b = new Uint8Array(n);
        let o = 0;
        for (const x of bufs) { b.set(x, o); o += x.length; }
        hide(this, '_b', b);
        this.type = opt && opt.type ? String(opt.type).toLowerCase() : '';
    }
    get size() { return this._b.length; }
    text() { return Promise.resolve(td(this._b)); }
    arrayBuffer() { return Promise.resolve(this._b.slice().buffer); }
    bytes() { return Promise.resolve(this._b.slice()); }
    slice(a, b, t) { const r = new Blob([], { type: t }); hide(r, '_b', this._b.slice(a, b)); return r; }
    stream() { return new ReadableStream(this._b); }
}
class File extends Blob {
    constructor(parts, name, opt) { super(parts, opt); this.name = String(name); this.lastModified = (opt && opt.lastModified) || Date.now(); }
}
class FileReader extends EventTarget {
    constructor() { super(); this.readyState = 0; this.result = null; this.error = null; this.onload = this.onloadend = this.onerror = null; }
    _done(r) {
        setTimeout(() => {
            this.readyState = 2;
            this.result = r;
            const ev = new ProgressEvent('load');
            if (typeof this.onload === 'function') safe(this.onload, [ev], this);
            dispatch(this, ev);
            if (typeof this.onloadend === 'function') safe(this.onloadend, [ev], this);
        }, 0);
    }
    readAsText(b) { this._done(td(b._b)); }
    readAsArrayBuffer(b) { this._done(b._b.slice().buffer); }
    readAsDataURL(b) { let s = ''; for (const c of b._b) s += String.fromCharCode(c); this._done('data:' + (b.type || 'application/octet-stream') + ';base64,' + btoa(s)); }
    readAsBinaryString(b) { let s = ''; for (const c of b._b) s += String.fromCharCode(c); this._done(s); }
    abort() { }
}
class ReadableStream {
    constructor(src) { hide(this, '_c', src instanceof Uint8Array ? [src] : []); this.locked = false; }
    getReader() {
        const c = this._c;
        this.locked = true;
        return { read: () => Promise.resolve(c.length ? { value: c.shift(), done: false } : { value: undefined, done: true }),
            releaseLock() { }, cancel() { return Promise.resolve(); }, closed: Promise.resolve() };
    }
    cancel() { return Promise.resolve(); }
    async *[Symbol.asyncIterator]() { for (const x of this._c) yield x; }
}
class FormData {
    constructor(form) {
        hide(this, '_l', []);
        if (form instanceof HTMLFormElement)
            for (const e of form.elements) {
                const n = e.getAttribute('name');
                if (!n || e.disabled) continue;
                if (e instanceof HTMLInputElement) {
                    const t = e.type;
                    if ((t === 'checkbox' || t === 'radio') && !e.checked) continue;
                    if (t === 'submit' || t === 'button' || t === 'reset' || t === 'image' || t === 'file') continue;
                }
                if (e instanceof HTMLButtonElement || e instanceof HTMLFieldSetElement) continue;
                this.append(n, e.value);
            }
    }
    append(k, v, f) { this._l.push([String(k), v instanceof Blob ? v : String(v)]); }
    set(k, v) { this.delete(k); this.append(k, v); }
    get(k) { const p = this._l.find(p => p[0] === String(k)); return p ? p[1] : null; }
    getAll(k) { return this._l.filter(p => p[0] === String(k)).map(p => p[1]); }
    has(k) { return this._l.some(p => p[0] === String(k)); }
    delete(k) { this._l = this._l.filter(p => p[0] !== String(k)); }
    forEach(f, self) { for (const [k, v] of this._l) f.call(self, v, k, this); }
    entries() { return this._l[Symbol.iterator](); }
    keys() { return this._l.map(p => p[0])[Symbol.iterator](); }
    values() { return this._l.map(p => p[1])[Symbol.iterator](); }
    [Symbol.iterator]() { return this.entries(); }
}
/* a body -> [text to send, its content type] */
function bodyOf(b) {
    if (b == null) return [null, null];
    if (typeof b === 'string') return [b, 'text/plain;charset=UTF-8'];
    if (b instanceof URLSearchParams) return [b.toString(), 'application/x-www-form-urlencoded;charset=UTF-8'];
    if (b instanceof FormData) {
        const bd = '----LexOSFormBoundary' + Math.random().toString(36).slice(2);
        let s = '';
        for (const [k, v] of b._l) {
            s += '--' + bd + '\r\nContent-Disposition: form-data; name="' + k + '"' + (v instanceof File ? '; filename="' + v.name + '"' : '') + '\r\n';
            if (v instanceof Blob) s += 'Content-Type: ' + (v.type || 'application/octet-stream') + '\r\n\r\n' + td(v._b) + '\r\n';
            else s += '\r\n' + v + '\r\n';
        }
        return [s + '--' + bd + '--\r\n', 'multipart/form-data; boundary=' + bd];
    }
    if (b instanceof Blob) return [td(b._b), b.type || null];
    if (b instanceof ArrayBuffer || ArrayBuffer.isView(b)) return [td(b instanceof ArrayBuffer ? new Uint8Array(b) : new Uint8Array(b.buffer, b.byteOffset, b.byteLength)), null];
    return [String(b), 'text/plain;charset=UTF-8'];
}
function netGet(method, url, headers, body, bin) {
    let h = '';
    headers.forEach((v, k) => { if (!/^(host|content-length|connection|user-agent|accept-encoding|cookie)$/.test(k)) h += k + ': ' + v + '\r\n'; });
    if (/^data:/i.test(url)) {
        const m = /^data:([^,;]*)(;base64)?,(.*)$/is.exec(url);
        if (!m) return [0, bin ? new ArrayBuffer(0) : '', url, ''];
        let raw = m[2] ? atob(m[3]) : decodeURIComponent(m[3]);
        const u = new Uint8Array(raw.length);
        for (let i = 0; i < raw.length; i++) u[i] = raw.charCodeAt(i) & 255;
        return [200, bin ? u.buffer : td(u), url, m[1] || 'text/plain'];
    }
    if (/^blob:/i.test(url)) {
        const b = blobURLs.get(url);
        if (!b) return [0, bin ? new ArrayBuffer(0) : '', url, ''];
        return [200, bin ? b._b.slice().buffer : td(b._b), url, b.type];
    }
    return lx.http(method, url, h, body, bin ? 1 : 0);
}
class Request {
    constructor(input, init) {
        init = init || {};
        const base = input instanceof Request ? input : null;
        this.url = base ? base.url : new URL(String(input), lx.base()).href;
        this.method = String(init.method || (base && base.method) || 'GET').toUpperCase();
        this.headers = new Headers(init.headers || (base && base.headers));
        hide(this, '_body', init.body !== undefined ? init.body : base ? base._body : null);
        this.signal = init.signal || (base && base.signal) || null;
        this.credentials = init.credentials || 'same-origin';
        this.mode = init.mode || 'cors';
        this.cache = init.cache || 'default';
        this.redirect = init.redirect || 'follow';
        this.referrer = 'about:client';
        this.integrity = init.integrity || '';
        this.keepalive = !!init.keepalive;
    }
    clone() { return new Request(this); }
    text() { return Promise.resolve(bodyOf(this._body)[0] || ''); }
    json() { return this.text().then(JSON.parse); }
}
class Response {
    constructor(body, init) {
        init = init || {};
        this.status = init.status === undefined ? 200 : init.status;
        this.statusText = init.statusText || (this.status === 200 ? 'OK' : '');
        this.ok = this.status >= 200 && this.status < 300;
        this.headers = new Headers(init.headers);
        this.url = init.url || '';
        this.redirected = false;
        this.type = 'basic';
        this.bodyUsed = false;
        let b;
        if (body == null) b = new Uint8Array(0);
        else if (body instanceof ArrayBuffer) b = new Uint8Array(body);
        else if (ArrayBuffer.isView(body)) b = new Uint8Array(body.buffer, body.byteOffset, body.byteLength);
        else if (body instanceof Blob) b = body._b;
        else b = te(bodyOf(body)[0]);
        hide(this, '_b', b);
    }
    get body() { return new ReadableStream(this._b); }
    _use() { if (this.bodyUsed) return Promise.reject(new TypeError('Body has already been consumed.')); this.bodyUsed = true; return Promise.resolve(this._b); }
    arrayBuffer() { return this._use().then(b => b.slice().buffer); }
    bytes() { return this._use().then(b => b.slice()); }
    text() { return this._use().then(td); }
    json() { return this.text().then(JSON.parse); }
    blob() { return this._use().then(b => new Blob([b], { type: this.headers.get('content-type') || '' })); }
    formData() { return this.text().then(t => { const f = new FormData(); for (const [k, v] of new URLSearchParams(t)) f.append(k, v); return f; }); }
    clone() { const r = new Response(this._b.slice(), { status: this.status, statusText: this.statusText, headers: this.headers, url: this.url }); return r; }
    static json(d, init) { const r = new Response(JSON.stringify(d), init); r.headers.set('content-type', 'application/json'); return r; }
    static error() { const r = new Response(null, { status: 0 }); r.type = 'error'; return r; }
    static redirect(u, s) { return new Response(null, { status: s || 302, headers: { location: String(u) } }); }
}
function fetch(input, init) {
    return new Promise((resolve, reject) => {
        let req;
        try { req = new Request(input, init); } catch (e) { reject(e); return; }
        if (req.signal && req.signal.aborted) { reject(req.signal.reason || new DOMException('The operation was aborted.', 'AbortError')); return; }
        later(() => {
            if (req.signal && req.signal.aborted) { reject(req.signal.reason || new DOMException('The operation was aborted.', 'AbortError')); return; }
            const [body, ct] = bodyOf(req._body);
            if (ct && !req.headers.has('content-type')) req.headers.set('content-type', ct);
            const r = netGet(req.method, req.url, req.headers, body, true);
            if (!r[0]) { reject(new TypeError('Failed to fetch')); return; }
            const res = new Response(r[1], { status: r[0], url: r[2], headers: r[3] ? { 'content-type': r[3] } : {} });
            res.redirected = r[2] !== req.url;
            resolve(res);
        });
    });
}
class XMLHttpRequestEventTarget extends EventTarget { }
handlers(XMLHttpRequestEventTarget.prototype, ['loadstart', 'progress', 'abort', 'error', 'load', 'timeout', 'loadend']);
class XMLHttpRequest extends XMLHttpRequestEventTarget {
    constructor() {
        super();
        Object.assign(this, { readyState: 0, status: 0, statusText: '', responseText: '', response: '', responseType: '', responseURL: '',
            responseXML: null, timeout: 0, withCredentials: false, upload: new XMLHttpRequestEventTarget() });
        hide(this, '_h', new Headers());
        hide(this, '_ct', '');
        hide(this, '_n', 0);
    }
    open(m, u, async) {
        this._m = String(m).toUpperCase();
        this._u = new URL(String(u), lx.base()).href;
        this._async = async !== false;
        this._h = new Headers();
        this._n++;
        this._st(1);
    }
    _st(s) { this.readyState = s; dispatch(this, new Event('readystatechange')); }
    _ev(t, o) { const ev = new ProgressEvent(t, o); dispatch(this, ev); }
    setRequestHeader(k, v) { this._h.append(k, v); }
    overrideMimeType(t) { this._mime = t; }
    getResponseHeader(k) { return this.readyState >= 2 && String(k).toLowerCase() === 'content-type' ? this._ct || null : null; }
    getAllResponseHeaders() { return this.readyState >= 2 && this._ct ? 'content-type: ' + this._ct + '\r\n' : ''; }
    send(body) {
        const n = this._n;
        const go = () => {
            if (n !== this._n || this._aborted) return;
            const [b, ct] = bodyOf(this._m === 'GET' || this._m === 'HEAD' ? null : body);
            if (ct && !this._h.has('content-type')) this._h.set('content-type', ct);
            const bin = this.responseType === 'arraybuffer' || this.responseType === 'blob';
            this._ev('loadstart');
            const r = netGet(this._m, this._u, this._h, b, bin);
            if (n !== this._n) return;
            if (!r[0]) { this.status = 0; this._st(4); this._ev('error'); this._ev('loadend'); return; }
            this.status = r[0];
            this.statusText = r[0] === 200 ? 'OK' : String(r[0]);
            this.responseURL = r[2];
            this._ct = r[3];
            this._st(2);
            this._st(3);
            const t = this.responseType;
            if (t === 'arraybuffer') this.response = r[1];
            else if (t === 'blob') this.response = new Blob([r[1]], { type: r[3] });
            else {
                this.responseText = r[1];
                if (t === 'json') { try { this.response = JSON.parse(r[1]); } catch (e) { this.response = null; } }
                else if (t === 'document') this.response = this.responseXML = newDocument(r[1]);
                else this.response = r[1];
            }
            const len = typeof r[1] === 'string' ? r[1].length : r[1].byteLength;
            this._st(4);
            this._ev('progress', { lengthComputable: true, loaded: len, total: len });
            this._ev('load', { lengthComputable: true, loaded: len, total: len });
            this._ev('loadend', { lengthComputable: true, loaded: len, total: len });
        };
        if (this._async) later(go); else go();
    }
    abort() { this._aborted = true; this._n++; if (this.readyState > 0 && this.readyState < 4) { this.readyState = 0; this._ev('abort'); this._ev('loadend'); } }
}
handlers(XMLHttpRequest.prototype, ['readystatechange']);
Object.assign(XMLHttpRequest, { UNSENT: 0, OPENED: 1, HEADERS_RECEIVED: 2, LOADING: 3, DONE: 4 });
class AbortSignal extends EventTarget {
    constructor() { super(); this.aborted = false; this.reason = undefined; this.onabort = null; }
    throwIfAborted() { if (this.aborted) throw this.reason; }
    static abort(r) { const c = new AbortController(); c.abort(r); return c.signal; }
    static timeout(ms) { const c = new AbortController(); setTimeout(() => c.abort(new DOMException('The operation timed out.', 'TimeoutError')), ms); return c.signal; }
    static any(list) { const c = new AbortController(); for (const s of list) { if (s.aborted) { c.abort(s.reason); break; } s.addEventListener('abort', () => c.abort(s.reason)); } return c.signal; }
}
class AbortController {
    constructor() { this.signal = new AbortSignal(); }
    abort(r) {
        const s = this.signal;
        if (s.aborted) return;
        s.aborted = true;
        s.reason = r === undefined ? new DOMException('signal is aborted without reason', 'AbortError') : r;
        const ev = new Event('abort');
        if (typeof s.onabort === 'function') safe(s.onabort, [ev], s);
        dispatch(s, ev);
    }
}
class WebSocket extends EventTarget {
    constructor(u) {
        super();
        this.url = String(u); this.readyState = 0; this.protocol = ''; this.extensions = ''; this.bufferedAmount = 0; this.binaryType = 'blob';
        this.onopen = this.onmessage = this.onerror = this.onclose = null;
        setTimeout(() => {
            this.readyState = 3;
            const e = new Event('error'), c = Object.assign(new Event('close'), { code: 1006, reason: '', wasClean: false });
            if (typeof this.onerror === 'function') safe(this.onerror, [e], this);
            dispatch(this, e);
            if (typeof this.onclose === 'function') safe(this.onclose, [c], this);
            dispatch(this, c);
        }, 0);
    }
    send() { throw new DOMException('WebSocket is not open.', 'InvalidStateError'); }
    close() { this.readyState = 3; }
}
Object.assign(WebSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 });
class EventSource extends WebSocket { constructor(u) { super(u); } }

/* ================================================================
 * observers: what's in sight (IntersectionObserver), sizes
 * ================================================================ */
const ios = [], ros = [];
let ioMark = '';
class IntersectionObserver {
    constructor(cb, o) {
        o = o || {};
        this._cb = cb;
        this._els = new Map();
        this.root = o.root || null;
        this.rootMargin = o.rootMargin || '0px';
        this.thresholds = [].concat(o.threshold === undefined ? 0 : o.threshold);
        const m = parseInt(this.rootMargin, 10);
        this._m = isNaN(m) ? 0 : m;
    }
    observe(el) { if (!this._els.has(el)) this._els.set(el, null); if (!ios.includes(this)) ios.push(this); ioMark = ''; lx.due(lx.now()); }
    unobserve(el) { this._els.delete(el); }
    disconnect() { this._els.clear(); const i = ios.indexOf(this); if (i >= 0) ios.splice(i, 1); }
    takeRecords() { return []; }
}
function checkIO() {
    const v = lx.view(), mark = lx.gen() + ':' + v[2];
    if (mark === ioMark) return;
    ioMark = mark;
    for (const io of ios.slice()) {
        const entries = [];
        for (const [el, was] of io._els) {
            const r = el.isConnected ? el.getBoundingClientRect() : new DOMRect();
            const shown = el.isConnected && (r.width > 0 || r.height > 0) && r.bottom >= -io._m && r.top <= v[1] + io._m && r.right >= 0 && r.left <= v[0];
            if (was === shown) continue;
            io._els.set(el, shown);
            const ih = shown ? Math.max(0, Math.min(r.bottom, v[1]) - Math.max(r.top, 0)) : 0;
            const ratio = shown ? (r.height ? Math.min(1, ih / r.height) : 1) : 0;
            entries.push({ target: el, isIntersecting: shown, intersectionRatio: shown ? Math.max(ratio, 0.01) : 0, boundingClientRect: r,
                intersectionRect: shown ? new DOMRect(r.x, Math.max(r.y, 0), r.width, ih) : new DOMRect(), rootBounds: new DOMRect(0, 0, v[0], v[1]), time: lx.now() });
        }
        if (entries.length) safe(io._cb, [entries, io]);
    }
    if (ios.length) ioMark = lx.gen() + ':' + lx.view()[2];
}
class ResizeObserver {
    constructor(cb) { this._cb = cb; this._els = new Map(); }
    observe(el) { this._els.set(el, ''); if (!ros.includes(this)) ros.push(this); lx.due(lx.now()); }
    unobserve(el) { this._els.delete(el); }
    disconnect() { this._els.clear(); const i = ros.indexOf(this); if (i >= 0) ros.splice(i, 1); }
}
let roMark = '';
function checkRO() {
    const mark = String(lx.gen());
    if (mark === roMark) return;
    roMark = mark;
    for (const ro of ros.slice()) {
        const entries = [];
        for (const [el, was] of ro._els) {
            const r = el.getBoundingClientRect(), k = r.width + 'x' + r.height;
            if (k === was) continue;
            ro._els.set(el, k);
            const box = [{ inlineSize: r.width, blockSize: r.height }];
            entries.push({ target: el, contentRect: new DOMRect(0, 0, r.width, r.height), borderBoxSize: box, contentBoxSize: box, devicePixelContentBoxSize: box });
        }
        if (entries.length) safe(ro._cb, [entries, ro]);
    }
}
class PerformanceObserver { constructor() { } observe() { } disconnect() { } takeRecords() { return []; } static get supportedEntryTypes() { return []; } }

/* ================================================================
 * computed styles, media queries, CSS
 * ================================================================ */
const csProxy = {
    get(t, k) {
        if (typeof k !== 'string') return t[k];
        if (k in t) return t[k];
        if (/^\d+$/.test(k)) return Object.keys(t._v)[+k] || '';
        const key = k === 'cssFloat' ? 'float' : kebab(k);
        return t._v[key] !== undefined ? t._v[key] : '';
    },
};
function getComputedStyle(el, pseudo) {
    const v = el instanceof Element ? lx.cstyle(el[N]) : { display: 'none' };
    if (pseudo) v.content = 'none';
    const inline = el instanceof HTMLElement && el.getAttribute('style') ? parseDecls(el.getAttribute('style')) : null;
    if (inline) for (const [k, d] of inline) if (v[k] === undefined) v[k] = d.v;
    const t = {
        _v: v,
        getPropertyValue(k) { return v[String(k)] !== undefined ? v[String(k)] : ''; },
        getPropertyPriority() { return ''; },
        item(i) { return Object.keys(v)[i] || ''; },
        get length() { return Object.keys(v).length; },
        get cssText() { return ''; },
        setProperty() { throw new DOMException('read-only', 'NoModificationAllowedError'); },
        removeProperty() { throw new DOMException('read-only', 'NoModificationAllowedError'); },
    };
    return new Proxy(t, csProxy);
}
function mediaOk(q) {
    const v = lx.view(), w = v[0], h = v[1];
    const one = s => {
        s = s.trim().toLowerCase();
        let not = false;
        if (s.startsWith('not ')) { not = true; s = s.slice(4); }
        s = s.replace(/^only\s+/, '');
        const parts = s.split(/\s+and\s+/);
        let ok = true;
        for (let p of parts) {
            p = p.trim();
            if (!p) continue;
            if (p === 'all' || p === 'screen') continue;
            if (p === 'print' || p === 'speech' || p === 'tv' || p === 'handheld') { ok = false; continue; }
            const m = /^\(\s*([a-z-]+)\s*(?::\s*([^)]+))?\)$/.exec(p);
            if (!m) { ok = false; continue; }
            const f = m[1], val = (m[2] || '').trim();
            const px = x => { const n = parseFloat(x); return /em$/.test(x) ? n * 16 : n; };
            switch (f) {
            case 'min-width': ok = ok && w >= px(val); break;
            case 'max-width': ok = ok && w <= px(val); break;
            case 'min-height': ok = ok && h >= px(val); break;
            case 'max-height': ok = ok && h <= px(val); break;
            case 'width': ok = ok && w === px(val); break;
            case 'orientation': ok = ok && val === (w >= h ? 'landscape' : 'portrait'); break;
            case 'prefers-color-scheme': ok = ok && val === 'light'; break;
            case 'prefers-reduced-motion': ok = ok && val === 'reduce'; break;
            case 'prefers-reduced-data': ok = ok && val === 'reduce'; break;
            case 'prefers-contrast': ok = ok && val === 'no-preference'; break;
            case 'hover': case 'any-hover': ok = ok && (!val || val === 'hover'); break;
            case 'pointer': case 'any-pointer': ok = ok && (!val || val === 'fine'); break;
            case 'color': ok = ok && true; break;
            case 'min-resolution': case '-webkit-min-device-pixel-ratio': case 'min--moz-device-pixel-ratio':
                ok = ok && parseFloat(val) <= 1; break;
            case 'display-mode': ok = ok && val === 'browser'; break;
            case 'forced-colors': ok = ok && val === 'none'; break;
            case 'scripting': ok = ok && val === 'enabled'; break;
            default: ok = false;
            }
        }
        return not ? !ok : ok;
    };
    return String(q).split(',').some(one);
}
class MediaQueryList extends EventTarget {
    constructor(q) { super(); this.media = String(q); this.onchange = null; }
    get matches() { return mediaOk(this.media); }
    addListener(f) { this.addEventListener('change', f); }
    removeListener(f) { this.removeEventListener('change', f); }
}
const CSS = {
    supports(p, v) {
        if (v === undefined) { const m = /^\s*\(?\s*([a-z-]+)\s*:/.exec(String(p)); if (!m) return /^selector\(/.test(String(p)); p = m[1]; }
        return !/^(-webkit-|-moz-|-ms-)?(backdrop-filter|mask|clip-path|container|anchor)/.test(String(p));
    },
    escape(s) { return String(s).replace(/([^a-zA-Z0-9_\u00A0-\uFFFF-])/g, '\\$1').replace(/^(\d)/, '\\3$1 '); },
    px: n => n + 'px', em: n => n + 'em', rem: n => n + 'rem', percent: n => n + '%',
    registerProperty() { },
};
const fonts = Object.assign(new EventTarget(), {
    status: 'loaded', size: 0, onloadingdone: null,
    load() { return Promise.resolve([]); }, check() { return true; }, add() { }, delete() { }, clear() { }, has() { return false; },
    forEach() { }, values() { return [][Symbol.iterator](); }, [Symbol.iterator]() { return [][Symbol.iterator](); },
});
fonts.ready = Promise.resolve(fonts);
class FontFace {
    constructor(family, src, d) { this.family = family; this.status = 'loaded'; Object.assign(this, d || {}); this.loaded = Promise.resolve(this); }
    load() { return Promise.resolve(this); }
}

/* ================================================================
 * the console, dialogs, the rest of window
 * ================================================================ */
function inspect(v, d) {
    if (typeof v === 'string') return d ? JSON.stringify(v) : v;
    if (v instanceof Error) return String(v) + (v.stack ? ' ' + String(v.stack).trim().split('\n')[0] : '');
    if (v instanceof Node) return v.nodeType === 1 ? '<' + v.localName + (v.id ? '#' + v.id : '') + (v.className ? '.' + String(v.className).trim().split(/\s+/).join('.') : '') + '>' : v.nodeName;
    if (typeof v === 'function') return 'function ' + (v.name || '') + '()';
    if (typeof v === 'symbol' || typeof v === 'bigint') return v.toString() + (typeof v === 'bigint' ? 'n' : '');
    if (v === null || typeof v !== 'object') return String(v);
    if ((d || 0) > 2) return Array.isArray(v) ? '[...]' : '{...}';
    try {
        if (Array.isArray(v)) return '[' + v.slice(0, 20).map(x => inspect(x, (d || 0) + 1)).join(', ') + (v.length > 20 ? ', ...' : '') + ']';
        const ks = Object.keys(v).slice(0, 12);
        return (v.constructor && v.constructor !== Object ? v.constructor.name + ' ' : '') + '{' + ks.map(k => k + ': ' + inspect(v[k], (d || 0) + 1)).join(', ') + (Object.keys(v).length > 12 ? ', ...' : '') + '}';
    } catch (e) { return '[object]'; }
}
function fmt(args) {
    args = Array.from(args);
    if (typeof args[0] === 'string' && /%[sdifoOc]/.test(args[0])) {
        let i = 1;
        args[0] = args[0].replace(/%([sdifoOc%])/g, (m, c) => {
            if (c === '%') return '%';
            if (i >= args.length) return m;
            const a = args[i++];
            return c === 'c' ? '' : c === 'd' || c === 'i' ? String(parseInt(a, 10)) : c === 'f' ? String(parseFloat(a)) : inspect(a, c === 's' ? 0 : 1);
        });
        args.splice(1, i - 1);
    }
    return args.map(a => inspect(a, 0)).join(' ');
}
const counts = Object.create(null), clocks = Object.create(null);
let indent = '';
const console = {
    log(...a) { lx.log(76, indent + fmt(a)); },
    info(...a) { lx.log(73, indent + fmt(a)); },
    debug(...a) { lx.log(68, indent + fmt(a)); },
    warn(...a) { lx.log(87, indent + fmt(a)); },
    error(...a) { lx.log(69, indent + fmt(a)); },
    trace(...a) { lx.log(68, indent + fmt(a)); },
    dir(o) { lx.log(76, indent + inspect(o, 0)); },
    dirxml(o) { lx.log(76, indent + inspect(o, 0)); },
    table(o) { lx.log(76, indent + inspect(o, 0)); },
    group(...a) { if (a.length) lx.log(76, indent + fmt(a)); indent += '  '; },
    groupCollapsed(...a) { console.group(...a); },
    groupEnd() { indent = indent.slice(2); },
    assert(c, ...a) { if (!c) lx.log(69, indent + 'Assertion failed: ' + fmt(a)); },
    count(l) { l = l || 'default'; counts[l] = (counts[l] || 0) + 1; lx.log(76, indent + l + ': ' + counts[l]); },
    countReset(l) { counts[l || 'default'] = 0; },
    time(l) { clocks[l || 'default'] = lx.now(); },
    timeLog(l, ...a) { l = l || 'default'; lx.log(76, indent + l + ': ' + (lx.now() - (clocks[l] || 0)) + 'ms ' + fmt(a)); },
    timeEnd(l) { l = l || 'default'; lx.log(76, indent + l + ': ' + (lx.now() - (clocks[l] || 0)) + 'ms'); delete clocks[l]; },
    clear() { },
    profile() { }, profileEnd() { }, timeStamp() { },
};
const performance_ = Object.assign(new EventTarget(), {
    now: () => lx.now(),
    timeOrigin: Date.now() - lx.now(),
    mark(n) { return { name: n, startTime: lx.now(), duration: 0, entryType: 'mark' }; },
    measure(n) { return { name: n, startTime: 0, duration: lx.now(), entryType: 'measure' }; },
    getEntries() { return []; }, getEntriesByType() { return []; }, getEntriesByName() { return []; },
    clearMarks() { }, clearMeasures() { }, clearResourceTimings() { }, setResourceTimingBufferSize() { },
    toJSON() { return {}; },
    navigation: { type: 0, redirectCount: 0 },
});
performance_.timing = { navigationStart: performance_.timeOrigin, fetchStart: performance_.timeOrigin, domLoading: performance_.timeOrigin,
    responseEnd: performance_.timeOrigin, domInteractive: 0, domContentLoadedEventEnd: 0, loadEventEnd: 0 };
const crypto_ = {
    getRandomValues(a) {
        for (let i = 0; i < a.length; i++) a[i] = Math.floor(Math.random() * 4294967296);
        return a;
    },
    randomUUID() {
        const h = '0123456789abcdef';
        let s = '';
        for (let i = 0; i < 36; i++) s += i === 8 || i === 13 || i === 18 || i === 23 ? '-' : i === 14 ? '4' : i === 19 ? h[8 + Math.floor(Math.random() * 4)] : h[Math.floor(Math.random() * 16)];
        return s;
    },
};
function structuredClone_(v, seen) {
    seen = seen || new Map();
    if (v === null || typeof v !== 'object') {
        if (typeof v === 'function' || typeof v === 'symbol') throw new DOMException('could not be cloned', 'DataCloneError');
        return v;
    }
    if (seen.has(v)) return seen.get(v);
    let r;
    if (v instanceof Date) r = new Date(v.getTime());
    else if (v instanceof RegExp) r = new RegExp(v.source, v.flags);
    else if (v instanceof Map) { r = new Map(); seen.set(v, r); for (const [k, x] of v) r.set(structuredClone_(k, seen), structuredClone_(x, seen)); return r; }
    else if (v instanceof Set) { r = new Set(); seen.set(v, r); for (const x of v) r.add(structuredClone_(x, seen)); return r; }
    else if (v instanceof ArrayBuffer) r = v.slice(0);
    else if (ArrayBuffer.isView(v)) r = new v.constructor(v);
    else if (v instanceof Blob) r = v;
    else if (v instanceof Node) throw new DOMException('could not be cloned', 'DataCloneError');
    else {
        r = Array.isArray(v) ? [] : {};
        seen.set(v, r);
        for (const k of Object.keys(v)) r[k] = structuredClone_(v[k], seen);
        return r;
    }
    seen.set(v, r);
    return r;
}
function Image(w, h) { const i = document.createElement('img'); if (w !== undefined) i.width = w; if (h !== undefined) i.height = h; return i; }
Image.prototype = HTMLImageElement.prototype;
function Audio(src) { const a = document.createElement('audio'); if (src !== undefined) a.src = src; return a; }
Audio.prototype = HTMLAudioElement.prototype;
function Option(text, value, defSel, sel) {
    const o = document.createElement('option');
    if (text !== undefined) o.text = text;
    if (value !== undefined) o.value = value;
    if (defSel) o.defaultSelected = true;
    if (sel) o.setAttribute('selected', '');
    return o;
}
Option.prototype = HTMLOptionElement.prototype;
class DOMParser {
    parseFromString(s, type) {
        const d = newDocument(/html/i.test(type || 'text/html') ? s : s.replace(/<\?xml[^>]*\?>/, ''));
        return d;
    }
}
class XMLSerializer { serializeToString(n) { return n.nodeType === 1 ? n.outerHTML : n.nodeType === 9 ? n.documentElement.outerHTML : n.textContent; } }
class Window extends EventTarget { }

/* ---- all of it into window ---- */
const document = W(docIds[0]);
try { Object.setPrototypeOf(G, Window.prototype); }
catch (e) { for (const k of ['addEventListener', 'removeEventListener', 'dispatchEvent']) hide(G, k, EventTarget.prototype[k]); }
const glob = {
    window: G, self: G, top: G, parent: G, frames: G, document, location, history, navigator, screen, customElements,
    clientInformation: navigator, opener: null, closed: false, name: '', length: 0, frameElement: null, status: '', defaultStatus: '',
    isSecureContext: /^https:/i.test(lx.url()), crossOriginIsolated: false, origin: (() => { try { return new URL(lx.url()).origin; } catch (e) { return 'null'; } })(),
    EventTarget, Event, UIEvent, MouseEvent, PointerEvent, WheelEvent, KeyboardEvent, FocusEvent, InputEvent, CustomEvent, ErrorEvent, ProgressEvent,
    MessageEvent, PopStateEvent, HashChangeEvent, PageTransitionEvent, SubmitEvent, StorageEvent, AnimationEvent, TransitionEvent, ClipboardEvent,
    CompositionEvent, MutationObserver, MutationRecord, WebKitMutationObserver: MutationObserver, IntersectionObserver, ResizeObserver, PerformanceObserver,
    Node, Element, HTMLElement, CharacterData, Text, CDATASection, Comment, DocumentFragment, ShadowRoot, Document, HTMLDocument: Document, Attr,
    NamedNodeMap, NodeList, HTMLCollection, DOMTokenList, CSSStyleDeclaration, CSSStyleSheet, StyleSheet: CSSStyleSheet, CSSRule: class CSSRule { },
    HTMLAnchorElement, HTMLAreaElement, HTMLImageElement, HTMLScriptElement, HTMLStyleElement, HTMLLinkElement, HTMLInputElement, HTMLTextAreaElement,
    HTMLSelectElement, HTMLOptionElement, HTMLOptGroupElement, HTMLButtonElement, HTMLFormElement, HTMLLabelElement, HTMLFieldSetElement,
    HTMLOutputElement, HTMLTemplateElement, HTMLCanvasElement, HTMLIFrameElement, HTMLMediaElement, HTMLVideoElement, HTMLAudioElement,
    HTMLDialogElement, HTMLDetailsElement, HTMLTableElement, HTMLTableSectionElement, HTMLTableRowElement, HTMLTableCellElement,
    HTMLMetaElement, HTMLTitleElement, HTMLBaseElement, HTMLProgressElement, HTMLMeterElement, HTMLSlotElement, HTMLSourceElement,
    HTMLObjectElement, HTMLEmbedElement, HTMLLIElement, HTMLOListElement, HTMLDataElement, HTMLTimeElement, HTMLQuoteElement, HTMLModElement,
    SVGElement, SVGSVGElement, SVGGraphicsElement, CanvasRenderingContext2D, Range, TreeWalker, NodeIterator: TreeWalker, NodeFilter, Selection: Object,
    DOMRect, DOMRectReadOnly, DOMPoint, DOMMatrix, WebKitCSSMatrix: DOMMatrix, URL, webkitURL: URL, URLSearchParams, Headers, Request, Response,
    fetch, XMLHttpRequest, XMLHttpRequestEventTarget, FormData, Blob, File, FileReader, ReadableStream, TextEncoder, TextDecoder, AbortController,
    AbortSignal, WebSocket, EventSource, Storage, MediaQueryList, FontFace, Image, Audio, Option, DOMParser, XMLSerializer, Window, CSS,
    setTimeout, setInterval, clearTimeout, clearInterval: clearTimeout, requestAnimationFrame, cancelAnimationFrame,
    webkitRequestAnimationFrame: requestAnimationFrame, webkitCancelAnimationFrame: cancelAnimationFrame,
    setImmediate: (f, ...a) => setTimeout(f, 0, ...a), clearImmediate: clearTimeout,
    requestIdleCallback: (f, o) => setTimeout(() => f({ didTimeout: false, timeRemaining: () => 8 }), Math.min(50, (o && o.timeout) || 50)),
    cancelIdleCallback: clearTimeout,
    getComputedStyle, matchMedia: q => new MediaQueryList(q), console, performance: performance_, crypto: crypto_,
    structuredClone: v => structuredClone_(v),
    alert: m => { lx.alert(sv(m)); }, confirm: m => { lx.alert(sv(m)); return true; }, prompt: (m, d) => { lx.alert(sv(m)); return d === undefined ? null : String(d); },
    print() { }, stop() { }, focus() { }, blur() { }, close() { }, moveTo() { }, moveBy() { }, resizeTo() { }, resizeBy() { }, find() { return false; },
    open(u) { lx.log(87, 'A pop-up window (not opened): ' + sv(u)); return null; },
    postMessage(data, origin) { setTimeout(() => fire(G, 'message', { data: structuredClone_(data), origin: location.origin, source: G }, MessageEvent), 0); },
    getSelection: () => selection,
    scrollTo(x, y) { const t = typeof x === 'object' && x ? x.top : y; if (t !== undefined) lx.scroll(+t || 0); },
    scrollBy(x, y) { const t = typeof x === 'object' && x ? x.top : y; lx.scroll(lx.view()[2] + (+t || 0)); },
    scroll(x, y) { G.scrollTo(x, y); },
    reportError: e => report(e),
};
for (const k of Object.keys(glob)) hide(G, k, glob[k]);
for (const n of Object.keys(simple)) hide(G, simple[n].name, simple[n]);
if (typeof G.queueMicrotask !== 'function') hide(G, 'queueMicrotask', f => { Promise.resolve().then(f).catch(report); });
Object.defineProperty(G, 'localStorage', { get() {
    if (!localStorage_) localStorage_ = new Proxy(new Storage(lsGet(), () => { lsDirty = true; lx.due(lx.now() + 300); }), stProxy);
    return localStorage_;
}, configurable: true });
hide(G, 'sessionStorage', sessionStorage_);
for (const [k, f] of [['innerWidth', () => lx.view()[0]], ['innerHeight', () => lx.view()[1]], ['outerWidth', () => 800], ['outerHeight', () => 600],
    ['scrollX', () => 0], ['scrollY', () => lx.view()[2]], ['pageXOffset', () => 0], ['pageYOffset', () => lx.view()[2]],
    ['screenX', () => 0], ['screenY', () => 0], ['screenLeft', () => 0], ['screenTop', () => 0], ['devicePixelRatio', () => 1],
    ['visualViewport', () => ({ width: lx.view()[0], height: lx.view()[1], scale: 1, offsetLeft: 0, offsetTop: 0, pageLeft: 0, pageTop: lx.view()[2], addEventListener() { }, removeEventListener() { } })],
    ['event', () => undefined]])
    Object.defineProperty(G, k, { get: f, set(v) { }, configurable: true });
handlers(Window.prototype, EVENTS.concat(WIN_EVENTS));
if (typeof G.atob !== 'function') {
    const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    hide(G, 'btoa', s => {
        s = String(s);
        let o = '';
        for (let i = 0; i < s.length; i += 3) {
            const a = s.charCodeAt(i), b = s.charCodeAt(i + 1), c = s.charCodeAt(i + 2);
            if (a > 255 || b > 255 || c > 255) throw new DOMException('The string to be encoded contains characters outside of the Latin1 range.', 'InvalidCharacterError');
            o += A[a >> 2] + A[(a & 3) << 4 | (b >> 4 || 0)] + (i + 1 < s.length ? A[(b & 15) << 2 | (c >> 6 || 0)] : '=') + (i + 2 < s.length ? A[c & 63] : '=');
        }
        return o;
    });
    hide(G, 'atob', s => {
        s = String(s).replace(/[\s=]/g, '');
        let o = '', bits = 0, n = 0;
        for (const ch of s) {
            const v = A.indexOf(ch);
            if (v < 0) throw new DOMException('The string to be decoded is not correctly encoded.', 'InvalidCharacterError');
            bits = bits << 6 | v; n += 6;
            if (n >= 8) { n -= 8; o += String.fromCharCode(bits >> n & 255); }
        }
        return o;
    });
}
G.addEventListener('unhandledrejection', () => { });

/* ================================================================
 * what js.h calls: the page begins, events come, time goes by
 * ================================================================ */
const SC = { 1: 'Escape', 14: 'Backspace', 15: 'Tab', 28: 'Enter', 57: ' ', 72: 'ArrowUp', 80: 'ArrowDown', 75: 'ArrowLeft', 77: 'ArrowRight',
    71: 'Home', 79: 'End', 73: 'PageUp', 81: 'PageDown', 82: 'Insert', 83: 'Delete', 87: 'F11', 88: 'F12', 42: 'Shift', 54: 'Shift',
    29: 'Control', 56: 'Alt', 58: 'CapsLock' };
const SCODE = { 1: 'Escape', 14: 'Backspace', 15: 'Tab', 28: 'Enter', 57: 'Space', 72: 'ArrowUp', 80: 'ArrowDown', 75: 'ArrowLeft', 77: 'ArrowRight',
    71: 'Home', 79: 'End', 73: 'PageUp', 81: 'PageDown', 82: 'Insert', 83: 'Delete', 12: 'Minus', 13: 'Equal', 26: 'BracketLeft',
    27: 'BracketRight', 39: 'Semicolon', 40: 'Quote', 41: 'Backquote', 43: 'Backslash', 51: 'Comma', 52: 'Period', 53: 'Slash' };
const KC = { Escape: 27, Backspace: 8, Tab: 9, Enter: 13, ' ': 32, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39, Home: 36, End: 35,
    PageUp: 33, PageDown: 34, Insert: 45, Delete: 46, Shift: 16, Control: 17, Alt: 18, CapsLock: 20 };
const ROWS = [[16, 'qwertyuiop'], [30, 'asdfghjkl'], [44, 'zxcvbnm'], [2, '1234567890']];
function keyInfo(ch, sc) {
    let letter = '';
    for (const [s0, r] of ROWS) if (sc >= s0 && sc < s0 + r.length) letter = r[sc - s0];
    for (let f = 0; f < 10; f++) if (sc === 59 + f) return { key: 'F' + (f + 1), code: 'F' + (f + 1), keyCode: 112 + f };
    if (sc === 87 || sc === 88) return { key: SC[sc], code: SC[sc], keyCode: sc === 87 ? 122 : 123 };
    const code = letter ? (/\d/.test(letter) ? 'Digit' + letter : 'Key' + letter.toUpperCase()) : SCODE[sc] || '';
    let key;
    if (ch >= 32 && ch !== 127) {
        let u = ch;
        if (ch >= 0x80 && ch <= 0xAF) u = 0x410 + ch - 0x80;
        else if (ch >= 0xE0 && ch <= 0xEF) u = 0x440 + ch - 0xE0;
        else if (ch === 0xF0) u = 0x401;
        else if (ch === 0xF1) u = 0x451;
        key = String.fromCharCode(u);
    } else if (ch === 13) key = 'Enter';
    else if (ch === 8) key = 'Backspace';
    else if (ch === 9) key = 'Tab';
    else if (ch === 27) key = 'Escape';
    else if (ch > 0 && ch < 27 && letter) key = letter;
    else key = SC[sc] || 'Unidentified';
    const kc = letter ? letter.toUpperCase().charCodeAt(0) : KC[key] || (key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0);
    return { key, code, keyCode: kc };
}
let hoverEl = null;
G.__lxEvent = function (type, node, x, y, key, code, mods) {
    try {
        const t = node ? W(node) : null, m = { shiftKey: !!(mods & 1), ctrlKey: !!(mods & 2) };
        switch (type) {
        case 'mousedown': case 'mouseup': case 'click': {
            const tg = t || document.body;
            const init = Object.assign({ bubbles: true, cancelable: true, view: G, clientX: x, clientY: y, button: 0, buttons: type === 'mousedown' ? 1 : 0, detail: 1 }, m);
            if (type !== 'click') fire(tg, type === 'mousedown' ? 'pointerdown' : 'pointerup', init, PointerEvent);
            const ev = fire(tg, type, init, MouseEvent);
            if (type === 'mousedown' && !ev.defaultPrevented) {
                const f = tg.closest && tg.closest('input,textarea,select,button,a[href],[tabindex]');
                if (f && f !== document.activeElement && f instanceof HTMLElement && !/^(input|textarea|select|button)$/.test(f.localName)) f.focus();
            }
            if (type === 'click' && !ev.defaultPrevented && tg instanceof Element) activate(tg, false);
            return ev.defaultPrevented;
        }
        case 'hover': {
            const old = hoverEl && hoverEl.isConnected ? hoverEl : null, nw = t;
            hoverEl = nw;
            const mk = (ty, tg, rel, bub, C) => fire(tg, ty, Object.assign({ bubbles: bub, cancelable: bub, view: G, clientX: x, clientY: y, relatedTarget: rel }, m), C);
            if (old && old !== nw) {
                mk('pointerout', old, nw, true, PointerEvent); mk('mouseout', old, nw, true, MouseEvent);
                for (let n = old; n && n.nodeType === 1 && !(nw && n.contains(nw)); n = n.parentElement) { mk('pointerleave', n, nw, false, PointerEvent); mk('mouseleave', n, nw, false, MouseEvent); }
            }
            if (nw && old !== nw) {
                mk('pointerover', nw, old, true, PointerEvent); mk('mouseover', nw, old, true, MouseEvent);
                const chain = [];
                for (let n = nw; n && n.nodeType === 1 && !(old && n.contains(old)); n = n.parentElement) chain.push(n);
                for (let i = chain.length - 1; i >= 0; i--) { mk('pointerenter', chain[i], old, false, PointerEvent); mk('mouseenter', chain[i], old, false, MouseEvent); }
            }
            if (nw) { mk('pointermove', nw, null, true, PointerEvent); mk('mousemove', nw, null, true, MouseEvent); }
            return false;
        }
        case 'keydown': case 'keypress': case 'keyup': {
            const k = keyInfo(key, code);
            const init = Object.assign({ bubbles: true, cancelable: true, view: G, key: k.key, code: k.code, keyCode: type === 'keypress' ? key : k.keyCode,
                which: type === 'keypress' ? key : k.keyCode, charCode: type === 'keypress' ? k.key.charCodeAt(0) : 0 }, m);
            return fire(t || document.body, type, init, KeyboardEvent).defaultPrevented;
        }
        case 'input':
            if (!t) return false;
            fire(t, 'input', { bubbles: true, data: key >= 32 ? keyInfo(key, code).key : null, inputType: key === 8 ? 'deleteContentBackward' : 'insertText' }, InputEvent);
            return false;
        case 'change': if (t) fire(t, 'change', { bubbles: true }); return false;
        case 'focus': if (t) { fire(t, 'focus', {}, FocusEvent); fire(t, 'focusin', { bubbles: true }, FocusEvent); } return false;
        case 'blur': if (t) { fire(t, 'blur', {}, FocusEvent); fire(t, 'focusout', { bubbles: true }, FocusEvent); } return false;
        case 'submit': return t ? fire(t, 'submit', { bubbles: true, cancelable: true }, SubmitEvent).defaultPrevented : false;
        case 'scroll': fire(document, 'scroll', { bubbles: true }); return false;
        case 'hashchange': fire(G, 'hashchange', { newURL: lx.url() }, HashChangeEvent); return false;
        }
    } catch (e) { report(e); }
    return false;
};
G.__lxTick = function (now) {
    if (netQ.length) { const q = netQ; netQ = []; for (const f of q) safe(f); }
    if (scriptQ.length) drainScripts();
    const t0 = lx.now();
    let ran = 0;
    for (;;) {
        let best = null;
        for (const t of timers.values()) if (t.at <= now && (!best || t.at < best.at || (t.at === best.at && t.id < best.id))) best = t;
        if (!best) break;
        if (best.every) best.at = Math.max(best.at + best.every, now + 1); else timers.delete(best.id);
        safe(best.fn, best.args, G);
        if (++ran > 100 || lx.now() - t0 > 200) break;
    }
    if (rafs.length && now - lastFrame >= 33) {
        lastFrame = now;
        const q = rafs;
        rafs = [];
        const ts = lx.now();
        for (const r of q) safe(r.fn, [ts], G);
    }
    if (ios.length) checkIO();
    if (ros.length) checkRO();
    if (lsDirty) { lsDirty = false; try { lx.lssave(JSON.stringify(lsGet())); } catch (e) { report(e); } }
    let next = Infinity;
    for (const t of timers.values()) if (t.at < next) next = t.at;
    if (rafs.length) next = Math.min(next, lastFrame + 33);
    if (netQ.length || scriptQ.length) next = now;
    if (lsDirty) next = Math.min(next, now + 300);
    return next === Infinity ? -1 : next;
};
G.__lxStart = function () {
    for (const id of lx.query(docIds[0], -1, 1, 'style')) fedStyles.set(id, lx.textof(id));
    for (const id of lx.query(docIds[0], selh('link[rel~=stylesheet]'), 1)) loadedLinks.add(id);
    const deferred = [], asyncs = [];
    for (const id of lx.query(docIds[0], -1, 1, 'script')) {
        if (lx.flags(id) & RAN) continue;
        const el = W(id), kind = scriptKind(el);
        if (!kind) { lx.setflag(id, RAN); continue; }
        if (kind === 'module' || (el.hasAttribute('src') && el.hasAttribute('defer'))) deferred.push(el);
        else if (el.hasAttribute('src') && el.hasAttribute('async')) asyncs.push(el);
        else runScript(el);
    }
    for (const el of deferred) runScript(el);
    readyState = 'interactive';
    fire(document, 'readystatechange');
    fire(document, 'DOMContentLoaded', { bubbles: true });
    for (const el of asyncs) runScript(el);
    for (const id of lx.query(docIds[0], -1, 1, '*')) { const t = lx.atom(lx.tag(id)); if (t.includes('-') && ceDefs.has(t)) W(id); }
    setTimeout(() => {
        drainScripts();
        readyState = 'complete';
        fire(document, 'readystatechange');
        for (const id of lx.query(docIds[0], -1, 1, 'img')) fire(W(id), 'load');
        fire(G, 'load', {});
        fire(G, 'pageshow', {}, PageTransitionEvent);
    }, 0);
};
})(__lx);
