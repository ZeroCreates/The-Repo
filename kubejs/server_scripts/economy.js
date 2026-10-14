const DEFAULT_STARTING_BALANCE = 5000
const DEFAULT_MAX_BALANCE = 2000000000
const HARD_MAX_BALANCE = 2000000000
const BALANCE_KEY = 'kubejs_economy_balance_cents'
const NOTE_TAG = 'kubejs_economy_note'
const NOTE_SIGNATURE = 'the_repo_economy_note_v1'
const DATA_COMPONENTS = Java.loadClass('net.minecraft.core.component.DataComponents')
const CURRENCY_TAG = 'kubejs_economy_currency'
const CURRENCY_SIGNATURE = 'the_repo_economy_currency_v1'
const BALANCES_FILE = 'kubejs/data/economy_balances.json'
const REDEEMABLES_FILE = 'kubejs/data/economy_redeemables.json'
const ACCOUNTS_FILE = 'kubejs/data/economy_accounts.json'
const SETTINGS_FILE = 'kubejs/data/economy_settings.json'
const DEFAULT_INTEREST_INTERVAL_HOURS = 24
const MAX_INTEREST_INTERVAL_HOURS = 24 * 365
const DEFAULT_DAILY_INTEREST_BASIS_POINTS = 100
const MAX_DAILY_INTEREST_BASIS_POINTS = 10000
const DEFAULT_MINIMUM_INTEREST_BALANCE_CENTS = 100
const DEFAULT_COOLDOWNS_MS = { withdraw: 5000, bank: 5000, redeem: 1000 }
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
let economySettings = JsonIO.read(SETTINGS_FILE)
if (!economySettings || typeof economySettings !== 'object' || Array.isArray(economySettings)) {
  economySettings = {}
}
let startingBalanceCents = Number(economySettings.startingBalanceCents)
if (!isFinite(startingBalanceCents) || startingBalanceCents < 0
    || startingBalanceCents > HARD_MAX_BALANCE || startingBalanceCents % 1 !== 0) {
  startingBalanceCents = DEFAULT_STARTING_BALANCE
  economySettings.startingBalanceCents = startingBalanceCents
}
let maxBalanceCents = Number(economySettings.maxBalanceCents)
if (!isFinite(maxBalanceCents) || maxBalanceCents < 1
    || maxBalanceCents > HARD_MAX_BALANCE || maxBalanceCents % 1 !== 0
    || startingBalanceCents > maxBalanceCents) {
  maxBalanceCents = DEFAULT_MAX_BALANCE
  economySettings.maxBalanceCents = maxBalanceCents
}
let dailyInterestBasisPoints = Number(economySettings.dailyInterestBasisPoints)
if (isNaN(dailyInterestBasisPoints) || dailyInterestBasisPoints < 0
    || dailyInterestBasisPoints > MAX_DAILY_INTEREST_BASIS_POINTS
    || dailyInterestBasisPoints % 1 !== 0) {
  dailyInterestBasisPoints = DEFAULT_DAILY_INTEREST_BASIS_POINTS
  economySettings.dailyInterestBasisPoints = dailyInterestBasisPoints
}
let interestIntervalHours = Number(economySettings.interestIntervalHours)
if (!isFinite(interestIntervalHours) || interestIntervalHours < 1
    || interestIntervalHours > MAX_INTEREST_INTERVAL_HOURS || interestIntervalHours % 1 !== 0) {
  interestIntervalHours = DEFAULT_INTEREST_INTERVAL_HOURS
  economySettings.interestIntervalHours = interestIntervalHours
}
let minimumInterestBalanceCents = Number(economySettings.minimumInterestBalanceCents)
if (!isFinite(minimumInterestBalanceCents) || minimumInterestBalanceCents < 1
    || minimumInterestBalanceCents > maxBalanceCents || minimumInterestBalanceCents % 1 !== 0) {
  minimumInterestBalanceCents = DEFAULT_MINIMUM_INTEREST_BALANCE_CENTS
  economySettings.minimumInterestBalanceCents = minimumInterestBalanceCents
}
const savedCooldowns = economySettings.cooldownsMs
  && typeof economySettings.cooldownsMs === 'object'
  && !Array.isArray(economySettings.cooldownsMs)
  ? economySettings.cooldownsMs
  : {}
let cooldownsMs = {}
Object.keys(DEFAULT_COOLDOWNS_MS).forEach(action => {
  const savedCooldown = Number(savedCooldowns[action])
  cooldownsMs[action] = isFinite(savedCooldown) && savedCooldown >= 0
    && savedCooldown <= 3600000 && savedCooldown % 1 === 0
    ? savedCooldown
    : DEFAULT_COOLDOWNS_MS[action]
})
economySettings.startingBalanceCents = startingBalanceCents
economySettings.maxBalanceCents = maxBalanceCents
economySettings.dailyInterestBasisPoints = dailyInterestBasisPoints
economySettings.interestIntervalHours = interestIntervalHours
economySettings.minimumInterestBalanceCents = minimumInterestBalanceCents
economySettings.cooldownsMs = cooldownsMs
JsonIO.write(SETTINGS_FILE, economySettings)
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
    let startingBalance = startingBalanceCents
    const oldData = player.persistentData
    if (oldData.contains(BALANCE_KEY)) {
      const oldBalance = oldData.getInt(BALANCE_KEY)
      if (oldBalance >= 0 && oldBalance <= maxBalanceCents) startingBalance = oldBalance
    }
    balances[id] = startingBalance
    saveBalances()
  }
  return Number(balances[id])
}

function saveAccounts() {
  JsonIO.write(ACCOUNTS_FILE, accounts)
}

function saveEconomySettings() {
  economySettings.startingBalanceCents = startingBalanceCents
  economySettings.maxBalanceCents = maxBalanceCents
  economySettings.dailyInterestBasisPoints = dailyInterestBasisPoints
  economySettings.interestIntervalHours = interestIntervalHours
  economySettings.minimumInterestBalanceCents = minimumInterestBalanceCents
  economySettings.cooldownsMs = cooldownsMs
  JsonIO.write(SETTINGS_FILE, economySettings)
}

function formatInterestRate() {
  return (dailyInterestBasisPoints / 100).toFixed(2).replace(/\.?0+$/, '')
}

function formatInterestInterval() {
  return interestIntervalHours + ' real-life hour(s)'
}

function formatCooldown(action) {
  return (cooldownsMs[action] / 1000).toFixed(3).replace(/\.?0+$/, '')
}

function getSavingsAccount(player) {
  const id = playerBalanceId(player)
  const now = Date.now()
  let account = accounts[id]
  if (!account || typeof account !== 'object') {
    account = { savings: 0, lastInterestAtMs: now, hidden: false }
    accounts[id] = account
  }

  account.savings = Math.max(0, Math.min(maxBalanceCents, Math.floor(Number(account.savings) || 0)))
  account.hidden = account.hidden === true
  account.username = String(player.username)
  let lastInterestAt = Number(account.lastInterestAtMs)
  if (isNaN(lastInterestAt) || lastInterestAt < 0 || lastInterestAt > now) {
    lastInterestAt = now
  }
  const interestIntervalMs = interestIntervalHours * 60 * 60 * 1000
  const completedIntervals = Math.floor((now - lastInterestAt) / interestIntervalMs)
  if (completedIntervals > 0 && dailyInterestBasisPoints > 0) {
    for (let interval = 0; interval < completedIntervals
        && account.savings >= minimumInterestBalanceCents
        && account.savings < maxBalanceCents; interval++) {
      const interest = Math.floor(account.savings * dailyInterestBasisPoints / 10000)
      if (interest < 1) break
      account.savings = Math.min(maxBalanceCents, account.savings + interest)
    }
  }
  account.lastInterestAtMs = lastInterestAt + completedIntervals * interestIntervalMs
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
  actionCooldowns[key] = Date.now() + cooldownsMs[action]
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
      || value > maxBalanceCents / 100) return null
  return Math.round(value * 100)
}

function sendCommandMessage(source, message) {
  source.sendSuccess(() => Text.of(message), false)
}

function notifyEconomyAdmins(player, message) {
  const auditMessage = '[Economy] ' + message
  console.info(auditMessage)
  try {
    const onlinePlayers = player.getServer().getPlayerList().getPlayers()
    for (let index = 0; index < onlinePlayers.size(); index++) {
      const admin = onlinePlayers.get(index)
      if (admin.hasPermissions(2)) admin.sendSystemMessage(Text.of(auditMessage))
    }
  } catch (error) {
    console.warn('Could not send economy admin notification: ' + error)
  }
}

function getMoneyNoteData(item) {
  const customData = item.get(DATA_COMPONENTS.CUSTOM_DATA)
  if (!customData) return null
  const root = customData.copyTag()
  if (!root.contains(NOTE_TAG)) return null
  return root.getCompound(NOTE_TAG)
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
          + ' | Savings: ' + formatMoney(account.savings) + ' | Interest: '
          + formatInterestRate() + '% every ' + formatInterestInterval())
        return 1
      })
      .then(Commands.literal('savings')
        .executes(context => {
          const player = context.source.player
          if (!player) return 0
          const account = getSavingsAccount(player)
          player.tell('Savings: ' + formatMoney(account.savings) + ' | Interest: '
            + formatInterestRate() + '% every ' + formatInterestInterval())
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
                player.tell('Enter a deposit amount from $0.01 to ' + formatMoney(maxBalanceCents) + '.')
                return 0
              }
              const checking = getBalance(player)
              const account = getSavingsAccount(player)
              if (cents > checking) {
                player.tell('Insufficient checking balance. Balance: ' + formatMoney(checking))
                return 0
              }
              if (account.savings + cents > maxBalanceCents) {
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
                player.tell('Enter a withdrawal amount from $0.01 to ' + formatMoney(maxBalanceCents) + '.')
                return 0
              }
              const checking = getBalance(player)
              const account = getSavingsAccount(player)
              if (cents > account.savings) {
                player.tell('Insufficient savings. Savings: ' + formatMoney(account.savings))
                return 0
              }
              if (checking + cents > maxBalanceCents) {
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
        .then(Commands.literal('settings')
          .executes(context => {
            sendCommandMessage(context.source, 'Economy settings:')
            sendCommandMessage(context.source, 'Starting balance: ' + formatMoney(startingBalanceCents))
            sendCommandMessage(context.source, 'Maximum balance: ' + formatMoney(maxBalanceCents))
            sendCommandMessage(context.source, 'Savings interest: ' + formatInterestRate()
              + '% every ' + formatInterestInterval())
            sendCommandMessage(context.source, 'Minimum savings for interest: '
              + formatMoney(minimumInterestBalanceCents))
            sendCommandMessage(context.source, 'Cooldowns (seconds): withdraw '
              + formatCooldown('withdraw') + ', bank ' + formatCooldown('bank')
              + ', redeem ' + formatCooldown('redeem'))
            return 1
          })
        )
        .then(Commands.literal('startingbalance')
          .then(Commands.argument('amount', Arguments.DOUBLE.create(event))
            .executes(context => {
              const cents = readAmountCents(Arguments.DOUBLE.getResult(context, 'amount'), true)
              if (cents == null) {
                sendCommandMessage(context.source, 'Enter a starting balance from $0.00 to '
                  + formatMoney(maxBalanceCents) + '.')
                return 0
              }
              startingBalanceCents = cents
              saveEconomySettings()
              sendCommandMessage(context.source, 'New players will start with '
                + formatMoney(startingBalanceCents) + '.')
              return 1
            })
          )
        )
        .then(Commands.literal('maxbalance')
          .then(Commands.argument('amount', Arguments.DOUBLE.create(event))
            .executes(context => {
              const amount = Arguments.DOUBLE.getResult(context, 'amount')
              const cents = Math.round(amount * 100)
              if (!isFinite(amount) || amount < 0.01 || amount > HARD_MAX_BALANCE / 100
                  || Math.abs(amount * 100 - cents) > 0.000001) {
                sendCommandMessage(context.source, 'Enter a maximum balance from $0.01 to '
                  + formatMoney(HARD_MAX_BALANCE) + ' with at most 2 decimal places.')
                return 0
              }
              if (cents < startingBalanceCents) {
                sendCommandMessage(context.source, 'Maximum balance cannot be below the starting balance of '
                  + formatMoney(startingBalanceCents) + '.')
                return 0
              }
              if (cents < minimumInterestBalanceCents) {
                sendCommandMessage(context.source, 'Maximum balance cannot be below the minimum savings balance for interest of '
                  + formatMoney(minimumInterestBalanceCents) + '.')
                return 0
              }
              for (const id of Object.keys(balances)) {
                if (Number(balances[id]) > cents) {
                  sendCommandMessage(context.source, "Maximum balance cannot be lower than a player's current checking balance.")
                  return 0
                }
              }
              for (const id of Object.keys(accounts)) {
                if (accounts[id] && Number(accounts[id].savings) > cents) {
                  sendCommandMessage(context.source, "Maximum balance cannot be lower than a player's current savings balance.")
                  return 0
                }
              }
              maxBalanceCents = cents
              saveEconomySettings()
              sendCommandMessage(context.source, 'Maximum account balance set to '
                + formatMoney(maxBalanceCents) + '.')
              return 1
            })
          )
        )
        .then(Commands.literal('cooldown')
          .then(Commands.argument('action', Arguments.STRING.create(event))
            .then(Commands.argument('seconds', Arguments.DOUBLE.create(event))
              .executes(context => {
                const action = Arguments.STRING.getResult(context, 'action').toLowerCase()
                const seconds = Arguments.DOUBLE.getResult(context, 'seconds')
                const milliseconds = Math.round(seconds * 1000)
                if (cooldownsMs[action] == null) {
                  sendCommandMessage(context.source, 'Choose a cooldown action: withdraw, bank, or redeem.')
                  return 0
                }
                if (!isFinite(seconds) || seconds < 0 || seconds > 3600
                    || Math.abs(seconds * 1000 - milliseconds) > 0.000001) {
                  sendCommandMessage(context.source, 'Enter a cooldown from 0 to 3600 seconds with at most 3 decimal places.')
                  return 0
                }
                cooldownsMs[action] = milliseconds
                saveEconomySettings()
                sendCommandMessage(context.source, action + ' cooldown set to '
                  + formatCooldown(action) + ' seconds.')
                return 1
              })
            )
          )
        )
        .then(Commands.literal('interest')
          .then(Commands.argument('percent', Arguments.DOUBLE.create(event))
            .executes(context => {
              const percent = Arguments.DOUBLE.getResult(context, 'percent')
              const basisPoints = Math.round(percent * 100)
              if (!isFinite(percent) || percent < 0 || percent > 100
                  || Math.abs(percent * 100 - basisPoints) > 0.000001) {
                sendCommandMessage(context.source, 'Enter an interest rate from 0% to 100% with at most 2 decimal places.')
                return 0
              }
              dailyInterestBasisPoints = basisPoints
              saveEconomySettings()
              sendCommandMessage(context.source, 'Savings interest set to '
                + formatInterestRate() + '% every ' + formatInterestInterval() + '.')
              return 1
            })
          )
        )
        .then(Commands.literal('interestinterval')
          .then(Commands.argument('hours', Arguments.INTEGER.create(event))
            .executes(context => {
              const hours = Arguments.INTEGER.getResult(context, 'hours')
              if (hours < 1 || hours > MAX_INTEREST_INTERVAL_HOURS) {
                sendCommandMessage(context.source, 'Enter an interest interval from 1 to '
                  + MAX_INTEREST_INTERVAL_HOURS + ' hours.')
                return 0
              }
              interestIntervalHours = hours
              saveEconomySettings()
              sendCommandMessage(context.source, 'Savings interest will be applied every '
                + formatInterestInterval() + '.')
              return 1
            })
          )
        )
        .then(Commands.literal('interestminimum')
          .then(Commands.argument('amount', Arguments.DOUBLE.create(event))
            .executes(context => {
              const cents = readAmountCents(Arguments.DOUBLE.getResult(context, 'amount'), false)
              if (cents == null || cents < 1) {
                sendCommandMessage(context.source, 'Enter a minimum savings balance from $0.01 to '
                  + formatMoney(maxBalanceCents) + '.')
                return 0
              }
              minimumInterestBalanceCents = cents
              saveEconomySettings()
              sendCommandMessage(context.source, 'Savings must hold at least '
                + formatMoney(minimumInterestBalanceCents) + ' to earn interest.')
              return 1
            })
          )
        )
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
                player.tell('Enter an amount from $0.01 to ' + formatMoney(maxBalanceCents) + '.')
                return 0
              }

              player.give(createMoneyNote(cents))
              player.tell('Created a money note worth ' + formatMoney(cents) + '.')
              notifyEconomyAdmins(player, player.username + ' created a money note worth '
                + formatMoney(cents) + '.')
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
                  sendCommandMessage(context.source, 'Enter an amount from $0.00 to ' + formatMoney(maxBalanceCents) + '.')
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
    var billCount = player.isShiftKeyDown() ? Number(item.count) : 1
    var billCents = redeemedDenomination.cents * billCount

    var balance = getBalance(player)
    if (balance + billCents > maxBalanceCents) {
      player.tell('Your balance is too high to redeem this bill or coin.')
      event.cancel()
      return
    }
    if (rejectCooldown(player, event, 'redeem')) return

    item.shrink(billCount)
    setBalance(player, balance + billCents)
    startCooldown(player, 'redeem')
    player.tell('Redeemed ' + billCount + ' ' + redeemedDenomination.label + '(s) for ' + formatMoney(billCents)
      + '. Balance: ' + formatMoney(balance + billCents))
    notifyEconomyAdmins(player, player.username + ' redeemed ' + billCount + ' '
      + redeemedDenomination.label + '(s) worth ' + formatMoney(billCents) + '.')
    event.cancel()
    return
  }

  if (itemId === 'minecraft:paper') {
    var data = getMoneyNoteData(item)
    if (data && readMoneyNoteString(data, 'signature') === NOTE_SIGNATURE) {
      var noteCents = Number(readMoneyNoteAmount(data))
      if (isNaN(noteCents) || noteCents < 1 || noteCents % 1 !== 0 || noteCents > maxBalanceCents) {
        player.tell('This money note is invalid.')
        return
      }

      var noteCount = player.isShiftKeyDown() ? Number(item.count) : 1
      var totalNoteCents = noteCents * noteCount
      var balance = getBalance(player)
      if (balance + totalNoteCents > maxBalanceCents) {
        player.tell('Your balance is too high to redeem this note.')
        return
      }
      if (rejectCooldown(player, event, 'redeem')) return

      item.shrink(noteCount)
      setBalance(player, balance + totalNoteCents)
      startCooldown(player, 'redeem')
      player.tell('Redeemed ' + noteCount + ' money note(s) worth ' + formatMoney(totalNoteCents)
        + '. Balance: ' + formatMoney(balance + totalNoteCents))
      notifyEconomyAdmins(player, player.username + ' redeemed ' + noteCount + ' money note(s) worth '
        + formatMoney(totalNoteCents) + '.')
      event.cancel()
      return
    }
  }

  var redeemableCents = Number(redeemableItems[itemId])
  if (isNaN(redeemableCents) || redeemableCents < 1 || redeemableCents % 1 !== 0) return
  var balance = getBalance(player)
  if (balance + redeemableCents > maxBalanceCents) {
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
