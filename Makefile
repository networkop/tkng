# That's because i have two hugo versions
HUGO := hugo-latest


DEFAULT: local

local: 
	${HUGO} server -D