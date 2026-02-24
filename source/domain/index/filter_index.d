module domain.index.filter_index;

import domain.index.base_index;
import std.stdint : uint32_t;

//! filter index refers to file index
alias FilterIndex = BaseIndex!uint32_t;
