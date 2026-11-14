// The filters of a document, the Filters page of its bottom panel: its filter
// sets (a row per set, a chip per rule), the commands on them and the editor
// of a rule. The sets live in the backend (DocumentFilters), per document:
// every command is done there and the panel is rendered again from what the
// backend has then, with the message of the command. The main view reloads
// when the filter operation reports completion (the panel of the document,
// onMainViewChanged).

import * as backend from "backend.js";
import * as platform from "platform.js";
import { editRule, filterFilesToLoad, filterExportDialog } from "pane-commands.js";
import { ruleColors, contrastText } from "rule-colors.js";
import { currentCatalog, tr } from "i18n/i18n.js";
import { fileFilter } from "file-types.js";

// What a rule does: the tooltip of its chip, its mark drawn by the class of
// .filter-kind (style.css)
const ruleKindTitles = {
    include: () => tr("Shows the records it matches"),
    exclude: () => tr("Hides the records it matches"),
    marker: () => tr("Marks the records it matches with its color"),
};

const noFilters = { canFilter: false, canDlf: false, active: false, sets: [] };

// The head of a set: its switch, name and buttons. Its set-index is read by the
// handlers of its switch and buttons (their parent).
function setHead(set, s) {
    return <div class="filter-set-head" set-index={s}>
        <input type="checkbox" class="filter-set-switch" />
        <span class="filter-name" title={set.source ? tr("Loaded from {file}", { file: set.source }) : ""}>{set.name}</span>
        <span class="filter-button filter-export" title={tr("Export to a filter file")}>⤓</span>
        <span class="filter-button filter-add" title={tr("Add a rule")}>+</span>
        <span class="filter-button filter-remove" title={tr("Remove this filter")}>×</span>
    </div>;
}

// The chip of a rule: its switch, the mark of its kind and its name, filled
// with the color of the rule and its text in the contrasting one; its buttons
// in a tab shown over it on hover, out of its width, in its color
// (--chip-color). Its set-index and rule-index are read by the handlers. Its
// tooltip (and its mark's: a cut name has a tooltip of its own) says what the
// rule does; a rule not applied is marked, its error in its tooltip.
function ruleChip(rule, s, r) {
    const classes = ["filter-chip"];
    if (rule.color) classes.push("colored");
    if (rule.error) classes.push("error");
    const kind = ruleKindTitles[rule.kind]?.() ?? "";
    const title = rule.error ? tr("Not applied: {error}", { error: rule.error }) : kind;
    const look = rule.color
        ? `background-color: ${rule.color}; color: ${contrastText(rule.color)}; --chip-color: ${rule.color}` : "";
    return <div class={classes.join(" ")} set-index={s} rule-index={r} title={title} style={look}>
        <input type="checkbox" class="filter-rule-switch" />
        <span class={"filter-kind " + rule.kind} title={kind} />
        <span class="filter-name">{rule.name || tr("(no name)")}</span>
        <span class="filter-chip-actions">
            <span class="filter-button filter-rule-edit" title={tr("Edit this rule (or double-click it)")}>✎</span>
            <span class="filter-button filter-rule-remove" title={tr("Remove this rule")}>×</span>
        </span>
    </div>;
}

// A block per set: its head, then its rules as chips wrapping under it; after
// it a line per rule not applied saying why. The chips shrink with the page
// (no overflow in a narrow window).
// The switches get their state here: the markup can't set it.
function renderSets(panel, sets) {
    sets.forEach((set, s) => {
        panel.append(<div class={set.enabled ? "filter-set" : "filter-set off"} />);
        const row = panel.lastElementChild;
        row.append(setHead(set, s));
        row.$(".filter-set-switch").value = set.enabled;
        row.append(<div class="filter-chips" />);
        const chips = row.lastElementChild;
        set.rules.forEach((rule, r) => {
            chips.append(ruleChip(rule, s, r));
            const chip = chips.lastElementChild;
            chip.$(".filter-rule-switch").value = rule.enabled;
        });
        for (const rule of set.rules)
            if (rule.error)
                panel.append(<div class="filter-note">{tr("{rule}: not applied: {error}",
                    { rule: rule.name || tr("(no name)"), error: rule.error })}</div>);
    });
}

export class FilterPanel {
    // @param root - the element of the panel (.filter-page), its events bound here
    // @param docId - the id of the document in the backend
    // @param host - what the panel asks of the document panel:
    //   theme() -> "light" | "dark" (of the rule editor),
    //   setRuleColors(colors) - the colors of the rules by rule id, for the tables,
    //     given whenever the panel is rendered (the rules may have changed),
    //   refreshRows() - the rows on screen refer to the rules again,
    //   setActive(active) - whether any rule works on the log (the backend's
    //     active: filters the view or colors the rows), given whenever the
    //     panel is rendered
    constructor(root, docId, host) {
        this.root = root;
        this.docId = docId;
        this.host = host;
        this.filters = noFilters; // what render() got last
        this.message = ""; // of the last command
        this.rendered = false; // built on the first show, and again when its texts are stale
        this.bind();
    }

    // Renders the panel if it wasn't since it was created or invalidated
    ensureRendered() {
        if (!this.rendered) this.render();
    }

    // The texts are stale (the language changed while the panel was hidden):
    // rendered again by the next ensureRendered()
    invalidate() {
        this.rendered = false;
    }

    // The language changed while the panel is shown
    languageChanged() {
        if (this.rendered) this.render();
    }

    // The document was reopened (Retry): its sets are those the backend restored,
    // and the message of a command before is about the document that was lost
    reopened() {
        this.message = "";
        this.render();
    }

    // Shows the sets after a command of the backend, with its message
    showResult(error) {
        this.message = error || "";
        this.render();
        this.host.refreshRows();
    }

    // Shows the filter sets
    render() {
        const info = backend.filters(this.docId) ?? noFilters;
        this.filters = info;
        this.rendered = true;
        const sets = info.sets ?? [];
        this.host.setRuleColors(ruleColors(sets)); // the rows refer to the rules by id
        this.host.setActive(Boolean(info.active));
        const panel = this.root.$(".filter-sets");
        const focused = this.focusedSwitch();
        // Built from scratch, as the quick filter was: reused inputs keep their state
        panel.clear();
        if (sets.length === 0)
            panel.append(<div class="filters-empty">{info.canFilter
                ? tr("No filters: load a filter file or create a new one")
                : tr("This log has no columns to filter by")}</div>);
        renderSets(panel, sets);
        const again = focused && panel.$(focused);
        if (again) again.state.focus = true;
        this.root.$(".btn-dlf").style.display = info.canFilter ? "" : "none";
        this.root.$(".btn-new-dlf").style.display = info.canFilter ? "" : "none";
        const message = this.root.$(".filter-message");
        message.innerText = this.message;
        // Not by :empty, which Sciter doesn't re-evaluate when the text changes
        message.style.display = this.message ? "" : "none";
        // Nothing to do on a log without columns to filter by: no empty strip
        this.root.$(".filter-toolbar").style.display = info.canFilter || this.message ? "" : "none";
    }

    // The switch of a set or a rule that has the focus (the user toggled it),
    // as a selector of the same switch once the sets are rendered anew; null
    // if the focus is elsewhere
    focusedSwitch() {
        const input = document.$(":focus");
        if (!input || !this.root.$(".filter-sets").contains(input)) return null;
        const owner = input.parentElement;
        const set = owner.getAttribute("set-index");
        if (input.classList.contains("filter-set-switch"))
            return `.filter-set-head[set-index="${set}"] > .filter-set-switch`;
        if (!input.classList.contains("filter-rule-switch")) return null;
        const rule = owner.getAttribute("rule-index");
        return `.filter-chip[set-index="${set}"][rule-index="${rule}"] > .filter-rule-switch`;
    }

    // Opens the editor of a rule of a set (rule -1: a new one) and applies
    // what it closes with, see editRule in pane-commands.js.
    // @returns true if the rule was applied, false if the editor was cancelled
    editRule(set, rule) {
        const docId = this.docId;
        const values = backend.filterRule(docId, set, rule);
        if (!values) return false;
        const open = (values, error) => platform.showModal("rule-editor.htm", {
            title: rule < 0 ? tr("New Rule") : tr("Edit Rule"), theme: this.host.theme(), rule: values, error,
            catalog: currentCatalog(),
            columns: backend.columns(docId),
            // What is wrong with the rule, while it is edited: the editor
            // marks it at once instead of being reopened with the error
            check: rule => backend.checkFilterRuleJson(docId, rule)
        });
        const apply = result => rule < 0 ? backend.addFilterRule(docId, set, result)
            : backend.updateFilterRule(docId, set, rule, result);
        if (!editRule(values, open, apply)) return false;
        this.showResult("");
        return true;
    }

    bind() {
        const docId = this.docId;
        const on = (event, selector, handler) => this.root.on(event, selector, handler);
        const setOf = (element) => parseInt(element.getAttribute("set-index"));
        const ruleOf = (element) => parseInt(element.getAttribute("rule-index"));

        // Filter sets are only appended; each one has its remove button. A filter
        // file of Log Tracy for any log, a .dlf for a DLT one.
        on("click", ".btn-dlf", () => {
            const fn = platform.chooseFileToOpen(fileFilter(filterFilesToLoad(this.filters.canDlf)));
            if (fn) this.showResult(backend.loadFilterFile(docId, fn));
        });

        // An empty set, kept with the log like a loaded one; its first rule is
        // asked for right away
        on("click", ".btn-new-dlf", () => {
            this.showResult(backend.newFilterSet(docId));
            if (this.message) return;
            const set = this.filters.sets.length - 1;
            // No first rule: no set either, so cancelled tries don't pile up
            if (!this.editRule(set, -1)) this.showResult(backend.removeFilterSet(docId, set));
        });

        on("click", ".filter-add", (evt, button) => {
            this.editRule(setOf(button.parentElement), -1);
            return true;
        });

        // A set is a copy kept with the log: exported to share it, to a filter file
        // of Log Tracy or (DLT logs) to a .dlf
        on("click", ".filter-export", (evt, button) => {
            const set = setOf(button.parentElement);
            // Offered the file the set was loaded from or exported to last, or
            // <name>.<format>.logfilter, see filterExportDialog
            const { types, ...dialog } = filterExportDialog(this.filters.canDlf, this.filters.sets[set]?.fileName || "");
            const fn = platform.chooseFileToSave({ ...dialog, filter: fileFilter(types) });
            if (fn) this.showResult(backend.exportFilterSet(docId, set, fn));
            return true;
        });

        on("click", ".filter-rule-edit", (evt, button) => {
            const row = button.closest(".filter-chip");
            this.editRule(setOf(row), ruleOf(row));
            return true;
        });

        on("dblclick", ".filter-chip", (evt, row) => {
            if (evt.target.tag === "input" || evt.target.closest(".filter-chip-actions")) return; // the switch, a button
            this.editRule(setOf(row), ruleOf(row));
            return true;
        });

        on("click", ".filter-rule-remove", (evt, button) => {
            const row = button.closest(".filter-chip");
            this.showResult(backend.removeFilterRule(docId, setOf(row), ruleOf(row)));
            return true;
        });

        on("change", ".filter-set-switch", (evt, input) => {
            this.showResult(backend.enableFilterSet(docId, setOf(input.parentElement), input.value));
        });

        on("change", ".filter-rule-switch", (evt, input) => {
            const row = input.parentElement;
            this.showResult(backend.enableFilterRule(docId, setOf(row), ruleOf(row), input.value));
        });

        on("click", ".filter-remove", (evt, button) => {
            this.showResult(backend.removeFilterSet(docId, setOf(button.parentElement)));
            return true;
        });
    }
}
