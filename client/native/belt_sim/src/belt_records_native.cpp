// belt_records.gd in C++ (belt_native_common.h Records): shared by BeltDrawNative and BeltLatticeNative.
#include "belt_native_common.h"

#include <godot_cpp/variant/packed_byte_array.hpp>

#include <algorithm>
#include <cstring>

using namespace godot;
using namespace godot::beltn;

// belt_records.gd `small`: pages of 4 rows, 8 at the start (else 16 rows, one at the start). Only before the
// first alloc.
void Records::set_small(bool small) {
	if (pages > 0 || top > 0) {
		return;
	}
	rows = small ? SMALL_ROWS : PAGE_ROWS;
	start_pages = small ? START_PAGES : 1;
	per_page = ROW * rows / TEXELS;
	page_floats = per_page * FLOATS;
}

void Records::grow(int n) {
	int need = (n + per_page - 1) / per_page;
	if (need <= pages) {
		return;
	}
	int p = std::max(start_pages, pages);
	while (p < need) {
		p *= 2;
	}
	pages = p;
	data.resize((size_t)pages * page_floats, 0.0f);
	all_dirty = true;
}

void Records::mark(int page) {
	if (page >= (int)dirty_f.size()) {
		dirty_f.resize(page + 1, 0);
	}
	if (!dirty_f[page]) {
		dirty_f[page] = 1;
		dirty.push_back(page);
	}
}

void Records::mark_range(int start, int n) {
	for (int p = start / per_page; p <= (start + std::max(n, 1) - 1) / per_page; p++) {
		mark(p);
	}
}

int Records::alloc(int n) {
	int size = MIN_RUN;
	while (size < n) {
		size *= 2;
	}
	auto f = free.find(size);
	if (f != free.end() && !f->second.empty()) {
		int r = f->second.back();
		f->second.pop_back();
		return r;
	}
	int start = top;
	top += size;
	grow(top);
	return start;
}

void Records::release(int start, int size) {
	if (size <= 0) {
		return;
	}
	for (int r = start; r < start + size; r++) {
		hide(r);
	}
	free[size].push_back(start);
}

void Records::copy(int from, int to, int n) {
	for (int k = 0; k < n * FLOATS; k++) {
		data[(size_t)to * FLOATS + k] = data[(size_t)from * FLOATS + k];
	}
	mark_range(to, n);
}

void Records::hide(int r) {
	size_t o = (size_t)r * FLOATS;
	for (int k = 0; k < FLOATS; k++) {
		data[o + k] = 0.0f;
	}
	data[o + 11] = HIDDEN;
	mark(r / per_page);
}

Dictionary Records::take_pages() {
	Array list;
	bool all = all_dirty;
	std::vector<int> which;
	if (all) {
		for (int p = 0; p < pages; p++) {
			which.push_back(p);
		}
	} else {
		which = dirty;
	}
	for (int p : which) {
		PackedByteArray bytes;
		bytes.resize((int64_t)page_floats * 4);
		memcpy(bytes.ptrw(), &data[(size_t)p * page_floats], (size_t)page_floats * 4);
		Array e;
		e.push_back(p);
		e.push_back(Image::create_from_data(ROW, rows, false, Image::FORMAT_RGBAF, bytes));
		list.push_back(e);
	}
	dirty.clear();
	std::fill(dirty_f.begin(), dirty_f.end(), 0);
	all_dirty = false;
	Dictionary d;
	d["all"] = all;
	d["pages"] = list;
	return d;
}
