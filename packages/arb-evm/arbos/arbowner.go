/*
* Copyright 2020, Offchain Labs, Inc.
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

package arbos

import (
	"math/big"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/abi"

	"github.com/offchainlabs/arbitrum/packages/arb-evm/arboscontracts"
	"github.com/offchainlabs/arbitrum/packages/arb-util/common"
	"github.com/offchainlabs/arbitrum/packages/arb-util/hashing"
)

var (
	giveOwnershipABI         abi.Method
	startArbOSUpgradeABI     abi.Method
	continueArbOSUpgradeABI  abi.Method
	finishArbOSUpgradeABI    abi.Method
	getUploadedCodeHashABI   abi.Method
	setChainParameterABI     abi.Method
	setFairGasPriceSenderABI abi.Method
	deployContractABI        abi.Method
	getTotalOfEthBalancesABI abi.Method
)

var FeesEnabledParamId *big.Int = new(big.Int).SetBytes(hashing.SoliditySHA3([]byte("FeesEnabled")).Bytes())
var ChainOwnerParamId *big.Int = new(big.Int).SetBytes(hashing.SoliditySHA3([]byte("ChainOwner")).Bytes())
var NetworkFeeRecipientParamId *big.Int = new(big.Int).SetBytes(hashing.SoliditySHA3([]byte("NetworkFeeRecipient")).Bytes())
var CongestionFeeRecipientParamId *big.Int = new(big.Int).SetBytes(hashing.SoliditySHA3([]byte("CongestionFeeRecipient")).Bytes())

func init() {
	arbowner, err := abi.JSON(strings.NewReader(arboscontracts.ArbOwnerABI))
	if err != nil {
		panic(err)
	}

	giveOwnershipABI = arbowner.Methods["giveOwnership"]
	startArbOSUpgradeABI = arbowner.Methods["startCodeUpload"]
	continueArbOSUpgradeABI = arbowner.Methods["continueCodeUpload"]
	finishArbOSUpgradeABI = arbowner.Methods["finishCodeUploadAsArbosUpgrade"]
	getUploadedCodeHashABI = arbowner.Methods["getUploadedCodeHash"]
	setChainParameterABI = arbowner.Methods["SetChainParameter"]
	setFairGasPriceSenderABI = arbowner.Methods["setFairGasPriceSender"]
	deployContractABI = arbowner.Methods["deployContract"]
	getTotalOfEthBalancesABI = arbowner.Methods["getTotalOfEthBalances"]
}

func GetTotalOfEthBalances() []byte {
	return makeFuncData(getTotalOfEthBalancesABI)
}

func GiveOwnershipData(newOwnerAddr common.Address) []byte {
	return makeFuncData(giveOwnershipABI, newOwnerAddr.ToEthAddress())
}

func StartArbOSUpgradeData() []byte {
	return makeFuncData(startArbOSUpgradeABI)
}

func ContinueArbOSUpgradeData(data []byte) []byte {
	return makeFuncData(continueArbOSUpgradeABI, data)
}

func FinishArbOSUpgradeData(targetCodeHash [32]byte) []byte {
	return makeFuncData(finishArbOSUpgradeABI, targetCodeHash)
}

func GetUploadedCodeHash() []byte {
	return makeFuncData(getUploadedCodeHashABI)
}

func SetFairGasPriceSender(sender common.Address, enable bool) []byte {
	return makeFuncData(setFairGasPriceSenderABI, sender, enable)
}

func SetFeesEnabled(enabled bool) []byte {
	enabledInt := big.NewInt(0)
	if enabled {
		enabledInt.SetInt64(1)
	}
	return makeFuncData(setChainParameterABI, FeesEnabledParamId, enabledInt)
}

func DeployContract(constructor []byte, sender common.Address, nonce *big.Int) []byte {
	return makeFuncData(deployContractABI, constructor, sender.ToEthAddress(), nonce)
}
