const STARTING_BALANCE = 5000
const MAX_BALANCE = 2000000000
const BALANCE_KEY = 'kubejs_economy_balance_cents'
const NOTE_TAG = 'kubejs_economy_note'
const NOTE_SIGNATURE = 'the_repo_economy_note_v1'
const REDEEMABLES_FILE = 'kubejs/data/economy_redeemables.json'
const savedRedeemableItems = JsonIO.read(REDEEMABLES_FILE)
let redeemableItems = savedRedeemableItems || {}
if (!savedRedeemableItems) {
  redeemableItems['minecraft:emerald'] = 2000
  JsonIO.write(REDEEMABLES_FILE, redeemableItems)
}

function getBalance(player) {
  const data = player.persistentData
  if (!data.contains(BALANCE_KEY)) {
    data.putInt(BALANCE_KEY, STARTING_BALANCE)
  }
  return data.getInt(BALANCE_KEY)
}

function setBalance(player, cents) {
  player.persistentData.putInt(BALANCE_KEY, cents)
}

function formatMoney(cents) {
  const dollars = Math.floor(cents / 100)
  const remainder = cents % 100
  return '$' + dollars + '.' + (remainder < 10 ? '0' : '') + remainder
}

function readAmountCents(value, allowZero) {
  if (isNaN(value) || value < 0 || (!allowZero && value === 0)
      || value > MAX_BALANCE / 100) return null
  return Math.round(value * 100)
}

function sendCommandMessage(source, message) {
  source.sendSuccess(() => Text.of(message), false)
}

PlayerEvents.loggedIn(event => {
  getBalance(event.player)
})

ServerEvents.commandRegistry(event => {
  const { commands: Commands, arguments: Arguments } = event

  event.register(
    Commands.literal('bal')
      .executes(context => {
        const player = context.source.player
        if (!player) return 0
        player.tell('Balance: ' + formatMoney(getBalance(player)))
        return 1
      })
  )

  event.register(
    Commands.literal('withdraw')
      .then(Commands.argument('amount', Arguments.DOUBLE.create(event))
        .executes(context => {
          const player = context.source.player
          if (!player) return 0

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
          const noteData = '{' + NOTE_TAG + ':{signature:"' + NOTE_SIGNATURE
            + '",amount:' + cents + '}}'
          const note = Item.of('minecraft:paper' + noteData)
            .withCustomName(Text.of(formatMoney(cents) + ' Money Note'))
          player.give(note)
          player.tell('Withdrew ' + formatMoney(cents) + '.')
          return 1
        })
      )
  )

  event.register(
    Commands.literal('setmoney')
      .requires(source => source.hasPermission(2))
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

  event.register(
    Commands.literal('redeemitem')
      .requires(source => source.hasPermission(2))
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
})

ItemEvents.rightClicked(event => {
  const player = event.player
  const item = event.item
  if (item.id === 'minecraft:paper') {
    const customData = item.getCustomData()
    const data = customData && customData[NOTE_TAG]
    if (data && data.signature === NOTE_SIGNATURE) {
      const cents = Number(data.amount)
      if (isNaN(cents) || cents < 1 || cents % 1 !== 0 || cents > MAX_BALANCE) {
        player.tell('This money note is invalid.')
        return
      }

      const balance = getBalance(player)
      if (balance + cents > MAX_BALANCE) {
        player.tell('Your balance is too high to redeem this note.')
        return
      }

      item.shrink(1)
      setBalance(player, balance + cents)
      player.tell('Redeemed ' + formatMoney(cents) + '. Balance: ' + formatMoney(balance + cents))
      event.cancel()
      return
    }
  }

  const cents = Number(redeemableItems[item.id])
  if (isNaN(cents) || cents < 1 || cents % 1 !== 0) return
  const balance = getBalance(player)
  if (balance + cents > MAX_BALANCE) {
    player.tell('Your balance is too high to redeem this item.')
    return
  }

  item.shrink(1)
  setBalance(player, balance + cents)
  player.tell('Redeemed 1 ' + item.id + ' for ' + formatMoney(cents)
    + '. Balance: ' + formatMoney(balance + cents))
  event.cancel()
})
