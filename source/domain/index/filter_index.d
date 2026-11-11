//! The index of the main view: the records the filters let through, as their indexes
//! in the offset index.
module domain.index.filter_index;

import domain.index.base_index;
import std.stdint : uint32_t;

//! filter index refers to file index
alias FilterIndex = BaseIndex!uint32_t;
