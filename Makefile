# That's because i have two hugo versions
HUGO := hugo-latest


DEFAULT: local

local: 
	${HUGO} server -D

chapter:
	hugo new --kind chapter newchapter/_index.md



# https://desk.draw.io/support/solutions/articles/16000042542-embed-html