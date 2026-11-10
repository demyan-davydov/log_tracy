// The search bar of a document panel (the toolbar of its search page): the
// chips of the query being edited, the search the results were found by, the
// mark of a query not searched yet and the message of the last run.

import { SearchEditor } from "search-editor.js";
import * as backend from "backend.js";
import { noSearch, runSearch, searchPending } from "pane-commands.js";

export class SearchBar {
    // @param root - the element of the bar (.search-bar of the search page), its events bound here
    // @param docId - the id of the document in the backend
    // @param host - what the bar asks of the document panel:
    //   setMatchColors(colors) - the colors of the chips the found fragments are shown in,
    //     given at once and whenever the search they were found by changes
    constructor(root, docId, host) {
        this.root = root;
        this.docId = docId;
        this.host = host;
        this.search = noSearch; // the search the results were found by (pane-commands.js)
        this.editor = new SearchEditor(root.$(".chip-search"), {
            checkRegex: (pattern, matchCase) => backend.checkRegex(pattern, matchCase),
            onEdited: () => this.updatePending(),
            onCommit: () => this.run(),
            history: () => backend.searchHistory(this.docId),
            historyButton: root.$(".btn-chip-history"),
        });
        this.host.setMatchColors(this.search.colors);
        this.updatePending();
        root.on("click", ".btn-chip-search", () => {
            this.editor.closeChip();
            this.run();
        });
    }

    // Runs the search for the chips of the editor (Enter, the Search button),
    // see runSearch
    run() {
        const editor = this.editor;
        const run = runSearch(this.search, editor.searchChips(), () => editor.searchChipColors(),
            () => editor.firstError(), chips => backend.startChipSearch(this.docId, chips));
        this.search = run.search;
        const message = this.root.$(".chip-search-message");
        message.innerText = run.message;
        // Not by :empty, which Sciter doesn't re-evaluate when the text changes
        message.style.display = run.message ? "" : "none";
        if (run.started) this.host.setMatchColors(this.search.colors); // before the results come
        this.updatePending();
    }

    // The document was reopened (Retry): it has no search yet
    reset() {
        this.search = noSearch;
        this.host.setMatchColors(this.search.colors);
        this.updatePending();
    }

    // Marks the query as not searched yet when it differs from the search shown
    updatePending() {
        const pending = searchPending(this.search, this.editor.searchChips());
        this.root.$(".chip-search-toolbar").classList.toggle("pending", pending);
        this.root.$(".btn-chip-search").classList.toggle("primary", pending);
    }

    destroy() {
        this.editor.destroy();
    }
}
