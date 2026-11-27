extends "res://tools/rl/race_probe.gd"
## CI: upstream's race probe (tools/rl/race_probe.gd: the race mode's grid of bots, headless,
## with lap times, overtakes, contacts, rescues, flips and the decision cost) with a choice of bot:
##
##   godot --headless --fixed-fps 120 --audio-driver Dummy --path . \
##       -s res://mobile/ci/race_battle.gd -- route=hanami runs=1 bot=plus|upstream
##
## bot=plus races every car with mobile/race/race_bot_plus.gd (attack, slipstream, the batched
## network; there is no player's car to defend against here), bot=upstream with RaceBot as
## shipped, so the two SUMMARY / COST lines compare the racing and the script cost.

const Plus := preload("res://mobile/race/race_bot_plus.gd")


func _spawn(car_id: String, pace: float, phase: int, contacts: bool) -> Dictionary:
	var e := super._spawn(car_id, pace, phase, contacts)
	if str(opts.get("bot", "upstream")) == "plus":
		var old: RaceBot = e["bot"]
		var bot: RaceBot = Plus.new()
		bot.name = "RaceBot"
		bot.track = old.track
		bot.pace = old.pace
		bot.phase = old.phase
		old.free()
		e["bot"] = bot
	return e
