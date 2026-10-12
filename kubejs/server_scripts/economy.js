const STARTING_BALANCE = 5000
const MAX_BALANCE = 2000000000
const BALANCE_KEY = 'kubejs_economy_balance_cents'
const NOTE_TAG = 'kubejs_economy_note'
const NOTE_SIGNATURE = 'the_repo_economy_note_v1'
const CURRENCY_TAG = 'kubejs_economy_currency'
const CURRENCY_SIGNATURE = 'the_repo_economy_currency_v1'
const BALANCES_FILE = 'kubejs/data/economy_balances.json'
const REDEEMABLES_FILE = 'kubejs/data/economy_redeemables.json'
const ACCOUNTS_FILE = 'kubejs/data/economy_accounts.json'
const INTEREST_WEEK_TICKS = 7 * 24000
const COOLDOWNS_MS = { withdraw: 5000, bank: 5000, redeem: 1000 }
const CURRENCY_DENOMINATIONS = [
  { kind: 'bill', cents: 10000, item: 'kubejs:bill_100', legacyItem: 'minecraft:paper', label: '$100 Bill' },
  { kind: 'bill', cents: 5000, item: 'kubejs:bill_50', legacyItem: 'minecraft:paper', label: '$50 Bill' },
  { kind: 'bill', cents: 2000, item: 'kubejs:bill_20', legacyItem: 'minecraft:paper', label: '$20 Bill' },
  { kind: 'bill', cents: 1000, item: 'kubejs:bill_10', legacyItem: 'minecraft:paper', label: '$10 Bill' },
  { kind: 'bill', cents: 500, item: 'kubejs:bill_5', legacyItem: 'minecraft:paper', label: '$5 Bill' },
  { kind: 'bill', cents: 100, item: 'kubejs:bill_1', legacyItem: 'minecraft:paper', label: '$1 Bill' },
  { kind: 'coin', cents: 50, item: 'kubejs:coin_50', legacyItem: 'minecraft:diamond', label: '50¢ Coin' },
  { kind: 'coin', cents: 25, item: 'kubejs:coin_25', legacyItem: 'minecraft:diamond', label: '25¢ Coin' },
  { kind: 'coin', cents: 10, item: 'kubejs:coin_10', legacyItem: 'minecraft:diamond', label: '10¢ Coin' },
  { kind: 'coin', cents: 5, item: 'kubejs:coin_5', legacyItem: 'minecraft:diamond', label: '5¢ Coin' },
  { kind: 'coin', cents: 1, item: 'kubejs:coin_1', legacyItem: 'minecraft:diamond', label: '1¢ Coin' }
]
let balances = JsonIO.read(BALANCES_FILE) || {}
let accounts = JsonIO.read(ACCOUNTS_FILE) || {}
let actionCooldowns = {}
const savedRedeemableItems = JsonIO.read(REDEEMABLES_FILE)
let redeemableItems = savedRedeemableItems || {}
if (!savedRedeemableItems) {
  redeemableItems['minecraft:emerald'] = 2000
  JsonIO.write(REDEEMABLES_FILE, redeemableItems)
}

function playerBalanceId(player) {
  return player.uuid.toString()
}

function saveBalances() {
  JsonIO.write(BALANCES_FILE, balances)
}

function getBalance(player) {
  const id = playerBalanceId(player)
  if (balances[id] == null) {
    let startingBalance = STARTING_BALANCE
    const oldData = player.persistentData
    if (oldData.contains(BALANCE_KEY)) {
      const oldBalance = oldData.getInt(BALANCE_KEY)
      if (oldBalance >= 0 && oldBalance <= MAX_BALANCE) startingBalance = oldBalance
    }
    balances[id] = startingBalance
    saveBalances()
  }
  return Number(balances[id])
}

function saveAccounts() {
  JsonIO.write(ACCOUNTS_FILE, accounts)
}

function getSavingsAccount(player) {
  const id = playerBalanceId(player)
  const gameTime = Number(player.level.dayTime)
  let account = accounts[id]
  if (!account || typeof account !== 'object') {
    account = { savings: 0, lastInterestAt: gameTime, hidden: false }
    accounts[id] = account
  }

  account.savings = Math.max(0, Math.min(MAX_BALANCE, Math.floor(Number(account.savings) || 0)))
  account.hidden = account.hidden === true
  account.username = String(player.username)
  let lastInterestAt = Number(account.lastInterestAt)
  if (isNaN(gameTime) || gameTime < 0) return account
  if (isNaN(lastInterestAt) || lastInterestAt < 0 || lastInterestAt > gameTime) {
    lastInterestAt = gameTime
  }
  const completedWeeks = Math.floor((gameTime - lastInterestAt) / INTEREST_WEEK_TICKS)
  if (completedWeeks > 0) {
    for (let week = 0; week < completedWeeks && account.savings < MAX_BALANCE; week++) {
      account.savings = Math.min(MAX_BALANCE, account.savings + Math.floor(account.savings / 100))
    }
    account.lastInterestAt = lastInterestAt + completedWeeks * INTEREST_WEEK_TICKS
  } else {
    account.lastInterestAt = lastInterestAt
  }
  saveAccounts()
  return account
}

function setBalance(player, cents) {
  balances[playerBalanceId(player)] = cents
  saveBalances()
}

function formatMoney(cents) {
  const dollars = Math.floor(cents / 100)
  const remainder = cents % 100
  return '$' + dollars + '.' + (remainder < 10 ? '0' : '') + remainder
}

function cooldownSecondsRemaining(player, action) {
  const key = playerBalanceId(player) + ':' + action
  return Math.max(0, Math.ceil(((actionCooldowns[key] || 0) - Date.now()) / 1000))
}

function startCooldown(player, action) {
  const key = playerBalanceId(player) + ':' + action
  actionCooldowns[key] = Date.now() + COOLDOWNS_MS[action]
}

function rejectCooldown(player, event, action) {
  const seconds = cooldownSecondsRemaining(player, action)
  if (seconds <= 0) return false
  player.tell('Wait ' + seconds + ' second(s) before doing that again.')
  if (event) event.cancel()
  return true
}

function createCurrencyItem(denomination, count) {
  return Item.of(denomination.item, count)
    .withCustomName(Text.of(denomination.label))
}

function createMoneyNote(cents) {
  const noteData = '{' + NOTE_TAG + ':{signature:"' + NOTE_SIGNATURE
    + '",amount:' + cents + '}}'
  return Item.of('minecraft:paper' + noteData)
    .withCustomName(Text.of('Money Note ' + formatMoney(cents)))
}

function giveCurrency(player, cents) {
  let remaining = cents
  CURRENCY_DENOMINATIONS.forEach(denomination => {
    const count = Math.floor(remaining / denomination.cents)
    if (count > 0) {
      player.give(createCurrencyItem(denomination, count))
      remaining %= denomination.cents
    }
  })
}

function readAmountCents(value, allowZero) {
  if (isNaN(value) || value < 0 || (!allowZero && value === 0)
      || value > MAX_BALANCE / 100) return null
  return Math.round(value * 100)
}

function sendCommandMessage(source, message) {
  source.sendSuccess(() => Text.of(message), false)
}

function getMoneyNoteData(item) {
  const roots = [item.nbt, item.tags]
  for (let index = 0; index < roots.length; index++) {
    const root = roots[index]
    if (!root) continue
    if (typeof root.getCompound === 'function'
        && typeof root.contains === 'function' && root.contains(NOTE_TAG)) {
      return root.getCompound(NOTE_TAG)
    }
    if (root[NOTE_TAG]) return root[NOTE_TAG]
  }
  return null
}

function readMoneyNoteString(data, key) {
  return typeof data.getString === 'function' ? data.getString(key) : data[key]
}

function readMoneyNoteAmount(data) {
  return typeof data.getInt === 'function' ? data.getInt('amount') : data.amount
}

PlayerEvents.loggedIn(event => {
  getBalance(event.player)
  getSavingsAccount(event.player)
})

ServerEvents.commandRegistry(event => {
  const { commands: Commands, arguments: Arguments } = event

  event.register(
    Commands.literal('bal')
      .executes(context => {
        const player = context.source.player
        if (!player) return 0
        const account = getSavingsAccount(player)
        player.tell('Checking: ' + formatMoney(getBalance(player))
          + ' | Savings: ' + formatMoney(account.savings))
        return 1
      })
  )

  event.register(
    Commands.literal('baltop')
      .executes(context => {
        const entries = []
        Object.keys(balances).forEach(id => {
          const account = accounts[id]
          if (!account || account.hidden || !account.username) return
          entries.push({ name: account.username, balance: Number(balances[id]) || 0 })
        })
        entries.sort((first, second) => second.balance - first.balance
          || first.name.localeCompare(second.name))
        if (entries.length === 0) {
          sendCommandMessage(context.source, 'There are no visible balances yet.')
          return 1
        }
        sendCommandMessage(context.source, 'Balance leaderboard:')
        entries.slice(0, 10).forEach((entry, index) => {
          sendCommandMessage(context.source, (index + 1) + '. ' + entry.name + ' - ' + formatMoney(entry.balance))
        })
        return 1
      })
      .then(Commands.literal('hide')
        .executes(context => {
          const player = context.source.player
          if (!player) return 0
          const account = getSavingsAccount(player)
          account.hidden = true
          saveAccounts()
          player.tell('Your balance is hidden from the leaderboard.')
          return 1
        })
      )
      .then(Commands.literal('show')
        .executes(context => {
          const player = context.source.player
          if (!player) return 0
          const account = getSavingsAccount(player)
          account.hidden = false
          saveAccounts()
          player.tell('Your balance is visible on the leaderboard.')
          return 1
        })
      )
  )

  event.register(
    Commands.literal('bank')
      .executes(context => {
        const player = context.source.player
        if (!player) return 0
        const account = getSavingsAccount(player)
        player.tell('Checking: ' + formatMoney(getBalance(player))
          + ' | Savings: ' + formatMoney(account.savings) + ' | Interest: 1% per in-game week')
        return 1
      })
      .then(Commands.literal('savings')
        .executes(context => {
          const player = context.source.player
          if (!player) return 0
          const account = getSavingsAccount(player)
          player.tell('Savings: ' + formatMoney(account.savings) + ' | Interest: 1% per in-game week')
          return 1
        })
        .then(Commands.literal('deposit')
          .then(Commands.argument('amount', Arguments.DOUBLE.create(event))
            .executes(context => {
              const player = context.source.player
              if (!player) return 0
              if (rejectCooldown(player, null, 'bank')) return 0
              const cents = readAmountCents(Arguments.DOUBLE.getResult(context, 'amount'), false)
              if (cents == null || cents < 1) {
                player.tell('Enter a deposit amount from $0.01 to $20,000,000.00.')
                return 0
              }
              const checking = getBalance(player)
              const account = getSavingsAccount(player)
              if (cents > checking) {
                player.tell('Insufficient checking balance. Balance: ' + formatMoney(checking))
                return 0
              }
              if (account.savings + cents > MAX_BALANCE) {
                player.tell('Your savings balance would exceed the account limit.')
                return 0
              }
              setBalance(player, checking - cents)
              account.savings += cents
              saveAccounts()
              startCooldown(player, 'bank')
              player.tell('Deposited ' + formatMoney(cents) + ' into savings.')
              return 1
            })
          )
        )
        .then(Commands.literal('withdraw')
          .then(Commands.argument('amount', Arguments.DOUBLE.create(event))
            .executes(context => {
              const player = context.source.player
              if (!player) return 0
              if (rejectCooldown(player, null, 'bank')) return 0
              const cents = readAmountCents(Arguments.DOUBLE.getResult(context, 'amount'), false)
              if (cents == null || cents < 1) {
                player.tell('Enter a withdrawal amount from $0.01 to $20,000,000.00.')
                return 0
              }
              const checking = getBalance(player)
              const account = getSavingsAccount(player)
              if (cents > account.savings) {
                player.tell('Insufficient savings. Savings: ' + formatMoney(account.savings))
                return 0
              }
              if (checking + cents > MAX_BALANCE) {
                player.tell('Your checking balance would exceed the account limit.')
                return 0
              }
              account.savings -= cents
              setBalance(player, checking + cents)
              saveAccounts()
              startCooldown(player, 'bank')
              player.tell('Moved ' + formatMoney(cents) + ' from savings to checking.')
              return 1
            })
          )
        )
      )
      .then(Commands.literal('checking')
        .executes(context => {
          const player = context.source.player
          if (!player) return 0
          player.tell('Checking balance: ' + formatMoney(getBalance(player)))
          return 1
        })
        .then(Commands.literal('withdraw')
          .then(Commands.argument('amount', Arguments.DOUBLE.create(event))
            .executes(context => {
              const player = context.source.player
              if (!player) return 0
              if (rejectCooldown(player, null, 'withdraw')) return 0

              const cents = readAmountCents(Arguments.DOUBLE.getResult(context, 'amount'), false)
              if (cents == null || cents < 1) {
                player.tell('Enter an amount greater than $0.00.')
                return 0
              }

              const balance = getBalance(player)
              if (cents > balance) {
                player.tell('Insufficient funds. Balance: ' + formatMoney(balance))
                return 0
              }

              setBalance(player, balance - cents)
              giveCurrency(player, cents)
              startCooldown(player, 'withdraw')
              player.tell('Withdrew ' + formatMoney(cents) + '.')
              return 1
            })
          )
        )
      )
      .then(Commands.literal('admin')
        .requires(source => source.hasPermission(2))
        .then(Commands.literal('moneynote')
          .then(Commands.argument('amount', Arguments.DOUBLE.create(event))
            .executes(context => {
              const player = context.source.player
              if (!player) {
                sendCommandMessage(context.source, 'Run this command as a player to receive the note.')
                return 0
              }

              const cents = readAmountCents(Arguments.DOUBLE.getResult(context, 'amount'), false)
              if (cents == null || cents < 1) {
                player.tell('Enter an amount from $0.01 to $20,000,000.00.')
                return 0
              }

              player.give(createMoneyNote(cents))
              player.tell('Created a money note worth ' + formatMoney(cents) + '.')
              return 1
            })
          )
        )
        .then(Commands.literal('setmoney')
          .then(Commands.argument('player', Arguments.PLAYER.create(event))
            .then(Commands.argument('amount', Arguments.DOUBLE.create(event))
              .executes(context => {
                const target = Arguments.PLAYER.getResult(context, 'player')
                const cents = readAmountCents(Arguments.DOUBLE.getResult(context, 'amount'), true)
                if (cents == null) {
                  sendCommandMessage(context.source, 'Enter an amount from $0.00 to $20,000,000.00.')
                  return 0
                }
                setBalance(target, cents)
                sendCommandMessage(context.source, 'Set ' + target.username + "'s balance to " + formatMoney(cents) + '.')
                target.tell('Your balance was set to ' + formatMoney(cents) + '.')
                return 1
              })
            )
          )
        )
        .then(Commands.literal('redeemitem')
          .then(Commands.literal('add')
            .then(Commands.argument('item', Arguments.STRING.create(event))
              .then(Commands.argument('amount', Arguments.DOUBLE.create(event))
                .executes(context => {
                  const itemId = Arguments.STRING.getResult(context, 'item').toLowerCase()
                  const cents = readAmountCents(Arguments.DOUBLE.getResult(context, 'amount'), false)
                  if (!Item.exists(itemId)) {
                    sendCommandMessage(context.source, 'Unknown item: ' + itemId)
                    return 0
                  }
                  if (cents == null || cents < 1) {
                    sendCommandMessage(context.source, 'Redeem value must be greater than $0.00.')
                    return 0
                  }
                  redeemableItems[itemId] = cents
                  JsonIO.write(REDEEMABLES_FILE, redeemableItems)
                  sendCommandMessage(context.source, itemId + ' now redeems for ' + formatMoney(cents) + '.')
                  return 1
                })
              )
            )
          )
          .then(Commands.literal('remove')
            .then(Commands.argument('item', Arguments.STRING.create(event))
              .executes(context => {
                const itemId = Arguments.STRING.getResult(context, 'item').toLowerCase()
                if (redeemableItems[itemId] == null) {
                  sendCommandMessage(context.source, itemId + ' is not redeemable.')
                  return 0
                }
                delete redeemableItems[itemId]
                JsonIO.write(REDEEMABLES_FILE, redeemableItems)
                sendCommandMessage(context.source, 'Removed ' + itemId + ' from redeemable items.')
                return 1
              })
            )
          )
          .then(Commands.literal('list')
            .executes(context => {
              const itemIds = Object.keys(redeemableItems).sort()
              if (itemIds.length === 0) {
                sendCommandMessage(context.source, 'There are no redeemable items.')
                return 1
              }
              itemIds.forEach(itemId => {
                sendCommandMessage(context.source, itemId + ' = ' + formatMoney(redeemableItems[itemId]))
              })
              return 1
            })
          )
        )
      )
  )
})

function redeemHeldItem(event) {
  const player = event.player
  const item = event.item
  if (!item) return
  const itemId = String(item.id)
  const denomination = CURRENCY_DENOMINATIONS.find(entry => entry.item === itemId)
  const redeemedDenomination = denomination
  if (redeemedDenomination) {
    var billCents = redeemedDenomination.cents

    var balance = getBalance(player)
    if (balance + billCents > MAX_BALANCE) {
      player.tell('Your balance is too high to redeem this bill or coin.')
      event.cancel()
      return
    }
    if (rejectCooldown(player, event, 'redeem')) return

    item.shrink(1)
    setBalance(player, balance + billCents)
    startCooldown(player, 'redeem')
    player.tell('Redeemed ' + redeemedDenomination.label + ' for ' + formatMoney(billCents)
      + '. Balance: ' + formatMoney(balance + billCents))
    event.cancel()
    return
  }

  if (itemId === 'minecraft:paper') {
    const data = getMoneyNoteData(item)
    if (data && readMoneyNoteString(data, 'signature') === NOTE_SIGNATURE) {
      var noteCents = Number(readMoneyNoteAmount(data))
      if (isNaN(noteCents) || noteCents < 1 || noteCents % 1 !== 0 || noteCents > MAX_BALANCE) {
        player.tell('This money note is invalid.')
        return
      }

      var balance = getBalance(player)
      if (balance + noteCents > MAX_BALANCE) {
        player.tell('Your balance is too high to redeem this note.')
        return
      }
      if (rejectCooldown(player, event, 'redeem')) return

      item.shrink(1)
      setBalance(player, balance + noteCents)
      startCooldown(player, 'redeem')
      player.tell('Redeemed ' + formatMoney(noteCents) + '. Balance: ' + formatMoney(balance + noteCents))
      event.cancel()
      return
    }
  }

  var redeemableCents = Number(redeemableItems[itemId])
  if (isNaN(redeemableCents) || redeemableCents < 1 || redeemableCents % 1 !== 0) return
  var balance = getBalance(player)
  if (balance + redeemableCents > MAX_BALANCE) {
    player.tell('Your balance is too high to redeem this item.')
    return
  }
  if (rejectCooldown(player, event, 'redeem')) return

  setBalance(player, balance + redeemableCents)
  startCooldown(player, 'redeem')
  player.tell('Redeemed 1 ' + itemId + ' for ' + formatMoney(redeemableCents)
    + '. Balance: ' + formatMoney(balance + redeemableCents))
  item.shrink(1)
  event.cancel()
}

ItemEvents.rightClicked(event => redeemHeldItem(event))
