# That's because i have two hugo versions
HUGO := hugo-latest

RANDOM_STR = 

DEFAULT: local

## Start a local server
local: 
	${HUGO} server -D

## Push the latest commit upstream
release:
	git add .
	git commit -m "$$(date)"
	git push
	
## Create a new chapter
chapter:
	hugo new --kind chapter newchapter/_index.md

# From: https://gist.github.com/klmr/575726c7e05d8780505a
help:
	@echo "$$(tput sgr0)";sed -ne"/^## /{h;s/.*//;:d" -e"H;n;s/^## //;td" -e"s/:.*//;G;s/\\n## /---/;s/\\n/ /g;p;}" ${MAKEFILE_LIST}|awk -F --- -v n=$$(tput cols) -v i=15 -v a="$$(tput setaf 6)" -v z="$$(tput sgr0)" '{printf"%s%*s%s ",a,-i,$$1,z;m=split($$2,w," ");l=n-i;for(j=1;j<=m;j++){l-=length(w[j])+1;if(l<= 0){l=n-i-length(w[j])-1;printf"\n%*s ",-i," ";}printf"%s ",w[j];}printf"\n";}'


# https://desk.draw.io/support/solutions/articles/16000042542-embed-html


