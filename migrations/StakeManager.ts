import { deployProxyImplementation } from '../lib'
import '@nomiclabs/hardhat-truffle5'
import { Artifacts } from 'hardhat/types'
import { RegistryContract } from 'typechain'

export async function deploy(artifacts: Artifacts, network: string, from: string) {
  await deployProxyImplementation(artifacts, 'StakeManager', network, from)
}