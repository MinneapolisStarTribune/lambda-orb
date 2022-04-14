set -eu

yamlBool() {
    echo "$1" | grep -qE '^(1|y|Y|yes|Yes|YES|t|T|true|True|TRUE|on|On|ON)$'
}

CommitSummary="$( git show --oneline --color=never ${CIRCLE_SHA1} | head -n1 | tr -d \\042 )"
DescStr="$( awk "BEGIN { printf \"${DESCFMT}\", \"${CIRCLE_USERNAME}\", \"${CIRCLE_BRANCH}\", \"${CommitSummary}\"} ")"

makeAlias() {
    if aws lambda get-alias --function-name "${FUNCARN}" --name "$1" > /dev/null 2>&1
    then
        aws lambda update-alias \
            --function-name "${FUNCARN}" \
            --name "$1" --function-version "$2" --description "${DescStr}" || return 1
    else
        aws lambda create-alias \
            --function-name "${FUNCARN}" \
            --name "$1" --function-version "$2" --description "${DescStr}" || return 1
    fi
    aws lambda wait function-updated-v2 --function-name "${FUNCARN}" --qualifier "$1"
}

T=$(mktemp -d)
# Find files, force all to fixed timestamp, sort, zip them into upload.zip
cd "${SRCPATH}"
find . | xargs touch -t 202102161400
find . -type f | sort | zip -o -MM -nw -@ -q -p -9 -X ${T}/upload.zip
# Calculate the AWS-style SHA256 Hash formatted as a base64 string
NewSha256=$(sha256sum ${T}/upload.zip | cut -c -64 | xxd -r -ps | base64)
# Query AWS to find the most recent version with this code, if any
LastVer=$( aws lambda list-versions-by-function --function-name "${FUNCARN}" \
    --query "Versions[?CodeSha256==\`${NewSha256}\`].Version" \
    | jq 'map(try tonumber) | max | numbers' )

# Is this code not in the version history for this function? (ie is LastVer empty?)
if [ -z "${LastVer:-}" ]
then
    # Upload source code to AWS
    ResultSha256=$(aws lambda update-function-code --function-name "${FUNCARN}" \
        --zip-file "fileb://${T}/upload.zip" | jq -r '.CodeSha256' )
    if [ "${NewSha256}" != "${ResultSha256}" ]
    then
        echo "Uploaded CodeSha256 result:"
        echo "${ResultSha256}"
        echo "did not match our original calculated value:"
        echo "${NewSha256}"
        echo "which is unexpected. Failing."
        exit 101
    fi
    aws lambda wait function-updated-v2 --function-name "${FUNCARN}"
    
    # Get new Version number
    Version=$(aws lambda publish-version --function-name "${FUNCARN}" \
        --code-sha256="${NewSha256}" --description "${DescStr}" | jq -r '.Version' )
    aws lambda wait function-updated-v2 --function-name "${FUNCARN}" --qualifier "${Version}"
else
    echo "Found and reusing existing version ${LastVer} of ${FUNCARN}."
    Version="${LastVer}"
fi

if yamlBool "${ALIASCM}"; then
    NewCommitAlias=git-${CIRCLE_SHA1:0:8}
    echo "Making a Commit Alias ${NewCommitAlias} for version ${Version}"
    makeAlias "${NewCommitAlias}" "${Version}"
fi

if yamlBool "${ALIASTG}"; then
    if [ -z "${CIRCLE_TAG:-}" ]; then
        echo "Cannot create Tag Alias due to commit not being tagged"
    else
        echo "Making a Tag Alias ${CIRCLE_TAG} for version ${Version}"
        makeAlias "${CIRCLE_TAG}" "${Version}"
    fi
fi

if yamlBool "${ALIASBR}"; then
    if [ -z "${CIRCLE_BRANCH:-}" ]; then
        echo "Cannot create Branch Alias due to commit not being on a branch"
    else
        echo "Making a Branch Alias ${CIRCLE_BRANCH} for version ${Version}"
        makeAlias "${CIRCLE_BRANCH}" "${Version}"
    fi
fi
