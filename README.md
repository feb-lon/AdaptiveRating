# Adaptive Rating

This is my Attempt at creating a Gachamon Rating System that where I tried to:
- Be similar to the original for "average" mons
- Make scores of combos / lack of combos more noticeable
- Give bigger punishment for unrunnable mons

---

## Rough outline how the score is being calculated:

- There are conditions a mon can fulfill. The variables are created at the beginning and are evaluated later. Examples are shed coverage, or availability of a fully accurate move.
- Instead of giving points for reaching thresholds (e.g. for stats) I tried to "make every point count". (e.g. often used tanh variations for stats)

### Abilites 
Rated similarily to the original with flat rating for most of them, as they often have little influence on other factors included in calculations here.

### Stats

Stats are roughly evaluated as Stat * Nature.

- Speed: Tanh variation
- Offense: Tanh variation
- Defense: 
    - defense to physical: HP * DEF, defense to special: HP * SPD
    - look up how scary different move types are for our mon, see whether our defenses are well-placed
- if defense look bad + speed looks bad, give extra penalty

### Moves


1. for each move:
    - check if banned / fixed rating / OHKO
    - else: 
        - if Move uses Power: 
            - power * powerRating is the "raw" rating
            - multiply it with multipliers relevant relevant to the moves power (like multihit, ability -> weather)
            - add ratings (not necessarily power related)
            - multiply with multipliers non-power related
        - if Move has status / stat change:
            - rate every status / stat change
            - this includes procc chance
        - Accuracy
            - rating-sum of previous * accuracy modifier (currently 1 - 1.5*accuracyMissing)
            - Abilites like Hustle / Compoundeyes is included in  calcs here
            - thunder + weather as well
        - various modifier like prep turn (not for drought + solar beam), self-confuse
        - setting flags for other moves (e.g. sleep move, so that dream eater is usable)
2. go through moves a 2nd time, check whether the flags set change other moves

### Calculate Rating