const fs = require('fs')
const path = require('path')
const { ethers } = require('ethers')

// Load mnemonic from file
const mnemonicPath = path.join(__dirname, 'mnemonic.txt')
if (!fs.existsSync(mnemonicPath)) {
  console.error('❌ mnemonic.txt not found in current directory.')
  process.exit(1)
}

const mnemonic = fs.readFileSync(mnemonicPath, 'utf8').trim()

const provider = new ethers.providers.JsonRpcProvider('https://mainnet.infura.io/v3/INSERT_YOUR_INFURA_KEY')

const hdNode = ethers.utils.HDNode.fromMnemonic(mnemonic)

const checkDepositAddresses = async () => {
  console.log('🔍 Checking deposit addresses (first 100)...\n')
  let foundAny = false

  for (let i = 0; i < 100; i++) {
    const path = `m/44'/60'/0'/0/${i}`
    const childNode = hdNode.derivePath(path)
    const address = ethers.utils.computeAddress(childNode.publicKey)

    const balance = await provider.getBalance(address)
    const ethBalance = ethers.utils.formatEther(balance)

    if (ethers.BigNumber.from(balance).gt(0)) {
      foundAny = true
      console.log(`💰 Unswept funds detected:`)
      console.log(`Index:       ${i}`)
      console.log(`Address:     ${address}`)
      console.log(`Balance:     ${ethBalance} ETH`)
      console.log('-----------------------------')
    }
  }

  if (!foundAny) {
    console.log('✅ No unswept balances detected in the first 100 deposit addresses.')
  }
}

checkDepositAddresses().catch(err => {
  console.error('❌ Error checking balances:', err.message)
})
