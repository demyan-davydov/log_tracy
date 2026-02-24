module domain.index.file_index;

import domain.index.base_index;
import std.stdint : uint32_t;

//! file index refers position of message in file
alias FileIndex = BaseIndex!uint32_t;
