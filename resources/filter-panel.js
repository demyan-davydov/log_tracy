// The filter panel of a document (the sidebar of its panel): its filter sets
// as rows, the commands on them and the editor of a rule. The sets live in the
// backend (DocumentFilters), per document: every command is done there and the
// panel is rendered again from what the backend has then, with the message of
// the command. The main view reloads when the filter operation reports
// completion (the panel of the document, onMainViewChanged).

import * as backend from "backend.js";
import * as platform from "platform.js";
import { editRule, filterFilesToLoad, filterExportDialog } from "pane-commands.js";
import { ruleColors } from "rule-colors.js";
import { currentCatalog, tr } from "i18n/i18n.js";
import { fileFilter } from "file-types.js";

const ruleKindMarks = { include: "+", exclude: "−", marker: "◆" };
const ruleKindTitles = {
    include: () => tr("Shows the records it matches"),
    exclude: () => tr("Hides the records it matches"),
    marker: () => tr("Marks the records it matches with its color"),
};

const noFilters = { canFilter: false, canDlf: false, sets: [] };

export class FilterPanel {
    // @param root - the element of the panel (.left-panel), its events bound here
    // @param docId - the id of the document in the backend
    // @param host - what the panel asks of the document panel:
    //   theme() -> "light" | "dark" (of the rule editor),
    //   setRuleColors(colors) - the colors of the rules by rule id, for the tables,
    //     given whenever the panel is rendered (the rules may have changed),
    //   refreshRows() - the rows on screen refer to the rules again
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

    // Shows the filter sets: a set is a row with its switch, name and remove
    // button, followed by a row per rule
    render() {
        const info = backend.filters(this.docId) ?? noFilters;
        this.filters = info;
        this.rendered = true;
        this.host.setRuleColors(ruleColors(info.sets)); // the rows refer to the rules by id
        const panel = this.root.$(".filter-sets");
        // Built from scratch, as the quick filter was: reused inputs keep their state
        panel.clear();
        if (!info.sets || info.sets.length === 0)
            panel.append(<div class="filters-empty">{info.canFilter
                ? tr("No filters: load a filter file or create a new one")
                : tr("This log has no columns to filter by")}</div>);
        (info.sets || []).forEach((set, s) => {
            const element = <div class={set.enabled ? "filter-set" : "filter-set off"}>
                <div class="filter-row filter-set-head" set-index={s}>
                    <input type="checkbox" class="filter-set-switch" />
                    <span class="filter-name" title={set.source ? tr("Loaded from {file}", { file: set.source }) : ""}>{set.name}</span>
                    <span class="filter-button filter-export" title={tr("Export to a filter file")}>⤓</span>
                    <span class="filter-button filter-add" title={tr("Add a rule")}>+</span>
                    <span class="filter-button filter-remove" title={tr("Remove this filter")}>×</span>
                </div>
            </div>;
            panel.append(element);
            const block = panel.lastElementChild;
            block.$(".filter-set-switch").value = set.enabled;
            set.rules.forEach((rule, r) => {
                const classes = ["filter-row", "filter-rule"];
                if (!rule.enabled) classes.push("off");
                if (rule.error) classes.push("error");
                block.append(<div class={classes.join(" ")} set-index={s} rule-index={r}>
                    <input type="checkbox" class="filter-rule-switch" />
                    <span class="filter-kind" title={ruleKindTitles[rule.kind]?.() ?? ""}>{ruleKindMarks[rule.kind]}</span>
                    <span class="filter-swatch" />
                    <span class="filter-name">{rule.name || tr("(no name)")}</span>
                    <span class="filter-button filter-rule-edit" title={tr("Edit this rule (or double-click it)")}>✎</span>
                    <span class="filter-button filter-rule-remove" title={tr("Remove this rule")}>×</span>
                </div>);
                const row = block.lastElementChild;
                row.$(".filter-rule-switch").value = rule.enabled;
                if (rule.color) row.$(".filter-swatch").style.setProperty("background-color", rule.color);
                if (rule.error)
                    block.append(<div class="filter-note">{tr("Not applied: {error}", { error: rule.error })}</div>);
            });
        });
        this.root.$(".btn-dlf").style.display = info.canFilter ? "" : "none";
        this.root.$(".btn-new-dlf").style.display = info.canFilter ? "" : "none";
        this.root.$(".filter-message").innerText = this.message;
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
        // file of DLT Explorer for any log, a .dlf of dlt-viewer for a DLT one.
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
        // of DLT Explorer or (DLT logs) to a .dlf for dlt-viewer
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
            const row = button.parentElement;
            this.editRule(setOf(row), ruleOf(row));
            return true;
        });

        on("dblclick", ".filter-rule", (evt, row) => {
            if (evt.target.tag === "input") return; // the switch
            this.editRule(setOf(row), ruleOf(row));
            return true;
        });

        on("click", ".filter-rule-remove", (evt, button) => {
            const row = button.parentElement;
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
