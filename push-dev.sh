#/bin/sh

TMPORB=$(mktemp)
circleci orb pack src/ > ${TMPORB} \
    && circleci orb validate ${TMPORB} \
    && circleci orb publish ${TMPORB} startribune/lambda@dev:init
rm -f ${TMPORB}