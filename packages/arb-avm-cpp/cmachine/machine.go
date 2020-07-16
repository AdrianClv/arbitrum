/*
 * Copyright 2019-2020, Offchain Labs, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package cmachine

/*
#cgo CFLAGS: -I.
#cgo LDFLAGS: -L. -L../build/rocksdb -lcavm -lavm -ldata_storage -lavm_values -lavm_utils -lstdc++ -lm -lrocksdb -lsecp256k1 -lff -lgmp -lkeccak
#include "../cavm/cmachine.h"
#include "../cavm/ccheckpointstorage.h"
#include <stdio.h>
#include <stdlib.h>
*/
import "C"

import (
	"bytes"
	"fmt"
	"runtime"
	"time"
	"unsafe"

	"github.com/offchainlabs/arbitrum/packages/arb-util/common"
	"github.com/offchainlabs/arbitrum/packages/arb-util/machine"
	"github.com/offchainlabs/arbitrum/packages/arb-util/protocol"
	"github.com/offchainlabs/arbitrum/packages/arb-util/value"
)

type Machine struct {
	c unsafe.Pointer
}

func New(codeFile string) (*Machine, error) {
	cFilename := C.CString(codeFile)

	cMachine := C.machineCreate(cFilename)

	if cMachine == nil {
		return nil, fmt.Errorf("error loading machine %v", codeFile)

	}
	ret := &Machine{cMachine}
	runtime.SetFinalizer(ret, cdestroyVM)
	C.free(unsafe.Pointer(cFilename))
	return ret, nil
}

func cdestroyVM(cMachine *Machine) {
	C.machineDestroy(cMachine.c)
}

func (m *Machine) Hash() (ret common.Hash) {
	C.machineHash(m.c, unsafe.Pointer(&ret[0]))
	return
}

func (m *Machine) Clone() machine.Machine {
	cMachine := C.machineClone(m.c)
	ret := &Machine{cMachine}
	runtime.SetFinalizer(ret, cdestroyVM)
	return ret
}

func (m *Machine) CurrentStatus() machine.Status {
	cStatus := C.machineCurrentStatus(m.c)
	switch cStatus {
	case C.STATUS_EXTENSIVE:
		return machine.Extensive
	case C.STATUS_ERROR_STOP:
		return machine.ErrorStop
	case C.STATUS_HALT:
		return machine.Halt
	default:
		panic("Unknown status")
	}
}

func (m *Machine) IsBlocked(newMessages bool) machine.BlockReason {
	newMessagesInt := 0
	if newMessages {
		newMessagesInt = 1
	}
	cBlockReason := C.machineIsBlocked(m.c, C.int(newMessagesInt))
	switch cBlockReason.blockType {
	case C.BLOCK_TYPE_NOT_BLOCKED:
		return nil
	case C.BLOCK_TYPE_HALT:
		return machine.HaltBlocked{}
	case C.BLOCK_TYPE_ERROR:
		return machine.ErrorBlocked{}
	case C.BLOCK_TYPE_BREAKPOINT:
		return machine.BreakpointBlocked{}
	case C.BLOCK_TYPE_INBOX:
		return machine.InboxBlocked{}
	default:
	}
	return nil
}

func (m *Machine) PrintState() {
	C.machinePrint(m.c)
}

func (m *Machine) ExecuteAssertion(
	maxSteps uint64,
	inbox value.TupleValue,
	maxWallTime time.Duration,
) (*protocol.ExecutionAssertion, uint64) {
	var buf bytes.Buffer
	_ = value.MarshalValue(inbox, &buf)

	msgData := buf.Bytes()
	msgDataC := C.CBytes(msgData)
	defer C.free(msgDataC)

	assertion := C.machineExecuteAssertion(
		m.c,
		C.uint64_t(maxSteps),
		msgDataC,
		C.uint64_t(uint64(maxWallTime.Seconds())),
	)

	outMessagesRaw := toByteSlice(assertion.outMessages)
	logsRaw := toByteSlice(assertion.logs)

	return protocol.NewExecutionAssertion(
		m.Hash(),
		int(assertion.didInboxInsn) != 0,
		uint64(assertion.numGas),
		outMessagesRaw,
		uint64(assertion.outMessageCount),
		logsRaw,
		uint64(assertion.logCount),
	), uint64(assertion.numSteps)
}

func (m *Machine) MarshalForProof() ([]byte, error) {
	rawProof := C.machineMarshallForProof(m.c)
	return C.GoBytes(unsafe.Pointer(rawProof.data), rawProof.length), nil
}

func (m *Machine) MarshalState() ([]byte, error) {
	stateData := C.machineMarshallState(m.c)
	return C.GoBytes(unsafe.Pointer(stateData.data), stateData.length), nil
}

func (m *Machine) Checkpoint(storage machine.CheckpointStorage) bool {
	cCheckpointStorage := storage.(*CheckpointStorage)
	success := C.checkpointMachine(m.c, cCheckpointStorage.c)

	return success == 1
}
