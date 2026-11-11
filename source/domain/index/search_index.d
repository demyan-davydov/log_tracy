//! The index of the search view: the records the search found, as their indexes in the
//! offset index.
module domain.index.search_index;

import domain.index.base_index;
import std.stdint : uint32_t;

//! search index refers to file index
alias SearchIndex = BaseIndex!uint32_t;
