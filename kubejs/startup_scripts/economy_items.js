StartupEvents.registry('item', event => {
  const currencies = [
    ['bill_100', '$100 Bill'],
    ['bill_50', '$50 Bill'],
    ['bill_20', '$20 Bill'],
    ['bill_10', '$10 Bill'],
    ['bill_5', '$5 Bill'],
    ['bill_1', '$1 Bill'],
    ['coin_50', '50¢ Coin'],
    ['coin_25', '25¢ Coin'],
    ['coin_10', '10¢ Coin'],
    ['coin_5', '5¢ Coin'],
    ['coin_1', '1¢ Coin']
  ]

  currencies.forEach(([id, name]) => {
    event.create(id).displayName(name).texture('kubejs:item/' + id)
  })
})
