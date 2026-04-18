// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#include "ProcessResolver.h"
#include <cstring>

ProcessResolver::ProcessResolver(bool resolveImmediately) : m_processMap() {
	if (resolveImmediately) {
		resolve();
	}
}

ProcessResolver::~ProcessResolver() {
	m_processMap.clear();
}

const ProcessResolver::ProcessMap &ProcessResolver::getProcessMap() const {
	return m_processMap;
}

void ProcessResolver::resolve() {
	// first clear the current lists
	m_processMap.clear();

	doResolve();
}

size_t ProcessResolver::amountOfProcesses() const {
	return m_processMap.size();
}


/// Helper function for adding an entry to the given process map
///
/// @param pid The process's PID
/// @param processName The name of the process
/// @param map The map to add the entry to
void addEntry(uint64_t pid, const char *processName, ProcessResolver::ProcessMap &map) {
	// 	In order to make sure the name pointer stays valid until we need it, we have ot copy it
	const size_t nameLength            = std::strlen(processName) + 1; // +1 for terminating NULL-byte
	std::unique_ptr< char[] > nameCopy = std::make_unique< char[] >(nameLength);

	std::strcpy(nameCopy.get(), processName);

	map.insert(std::make_pair(pid, std::move(nameCopy)));
}

// Code taken from https://stackoverflow.com/questions/49506579/how-to-find-the-pid-of-any-process-in-mac-osx-c
#include <libproc.h>

void ProcessResolver::doResolve() {
	pid_t pids[2048];
	unsigned int bytes  = static_cast< unsigned int >(proc_listpids(PROC_ALL_PIDS, 0, pids, sizeof(pids)));
	unsigned int n_proc = static_cast< unsigned int >(bytes / sizeof(pids[0]));
	for (unsigned int i = 0; i < n_proc; i++) {
		struct proc_bsdinfo proc;
		int st = proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &proc, PROC_PIDTBSDINFO_SIZE);
		if (st == PROC_PIDTBSDINFO_SIZE) {
			addEntry(static_cast< std::uint64_t >(pids[i]), proc.pbi_name, m_processMap);
		}
	}
}
