#!/bin/bash
# Copyright (c) Microsoft Corporation. All Rights Reserved.
# Licensed under the MIT license. See LICENSE file on the project webpage for details.

debug="" # or ="true"

tagFile=
repoFolder=

help()
{
    SCRIPT_NAME=`basename "$0"`

    echo
    echo " This script $SCRIPT_NAME will tag a commit in a repository"
    echo " Options:"
    echo
    echo "  -r|--repo-folder-path   folder that contains repositories will"
    echo "                              be created if doesn't exit and"
    echo "                              repos will be cloned if missing"
    echo
    echo "  -t|--tag-info-file      specially formatted input file"
    echo "      <subFolder>,<remoteGitUrl>,<branch>,<hashValue>,<newTag>,<tagDesc>"
    echo
    echo "          Note: delimeters are commas so values shouldn't contain them"
    echo "                  (wrapping values in quotations is not a workaround)"
    echo "          Note: only tag descriptions should have spaces."
    echo "                  (spaces in other values will be interpreted as _)"
    echo "          Note: subFolder,hashValue are optional."
    echo "                  subFolder=\"\" will use part of the URL"
    echo "                      (matching the default clone behavior)"
    echo "                  hashValue=\"\" will use the latest commit"
    echo
    echo " Please use full paths insted of relative"
    echo
    exit 2
}

# Parse script parameters
parse_args()
{
    while [[ "$#" -gt 0 ]] ; do

        # Output parameters to facilitate troubleshooting
        echo "Option $1 set with value $2"

        case "$1" in
            -t|--tag-info-file)
                tagFile=$2
                shift # argument
                ;;
            -r|--repo-folder-path)
                repoFolder=$2
                shift # argument
                ;;
            -h|--help)
                help
                ;;
            *) # unknown option
                echo "ERROR. Option -${BOLD}$2${NORM} not allowed."
                help
                ;;
        esac

        shift # argument
    done
}

validate_input()
{
    if [[ ! -d $repoFolder ]] ; then
        mkdir -p $repoFolder
    fi
    cd $repoFolder

    if [[ ! -f $tagFile ]] ; then
        echo "tag info file required."
        echo "Path: $tagFile is not a file"
        help
    fi
}

get_current_local_tags()
{
    # First see if there are named tag(s) for the current commit.
    # Allow errors. This syntax isn't supported on old versions of git (like 1.7.9.5)
    set +e
    tagInfo=`git tag -l --points-at HEAD 2> /dev/null | sed -e 's/^/  /'`
    set -e

    # For old versions of git (like 1.7.9.5)
    if [[ -z "$tagInfo" ]] ; then
        prefix="tag: "
        # Get information, split into multiple lines, only keep values prefixed with 'tag:', remove prefix
        tagInfo=`git log -g --decorate -1 | tr ',' '\n' | tr ')' '\n' | grep -o -i "${prefix}.*" | sed "s/${prefix}/  /g"`
    fi

    echo "$tagInfo"
}

make_report()
{
    report=""
    if [[ -z "$3" ]] ; then
        report="$1"
    else
        report="$1 on local: $2 and/or remote: $3"
    fi

    # Log to console immediately
    echo "$report"

    # Save message for later
    finalReport="${finalReport}\n\n  ${report}"
}
is_empty()
{
    [[ -z $1 ]] || [[ $1 == '""' ]] || [[ $1 == '""""' ]] || [[ $1 == '""""""' ]]
}

# Parse script argument(s)
parse_args $@

validate_input

finalReport=

while read entry ; do
    # Extract input. (empty cells like ,, -> ,"", ) THEN (spaces -> _ then commas -> spaces)
    inputArray=(`echo "$entry" | sed 's/,,/,"",/g' | tr ' ' '_' | tr ',' ' '`)
    subFolder=${inputArray[0]}
    remoteUrl=${inputArray[1]}
    gitBranch=${inputArray[2]}
    hashValue=${inputArray[3]} # Can be short or complete git hash.
    newGitTag=${inputArray[4]}
    # Extract message. (restore spaces)
    tagMessage=`echo ${inputArray[5]} | tr '_' ' '`

    # Input
    echo "subFolder:  $subFolder"
    echo "remoteUrl:  $remoteUrl"
    echo "gitBranch:  $gitBranch"
    echo "hashValue:  $hashValue"
    echo "newGitTag:  $newGitTag"
    echo "tagMessage: $tagMessage"
    echo
    # Debugging
    if [[ -n $debug ]] ; then
        continue
    fi

    # Reset working directory
    cd $repoFolder

    # Get local copy of the git repository.
    if is_empty $subFolder ; then
        subFolder=`basename "$remoteUrl" .git`
        echo "new subFolder:  $subFolder"
        echo
    fi
    if [[ ! -d $subFolder ]] ; then
        echo "cloning $remoteUrl to $subFolder directory"
        echo "This may take a bit..."
        git clone --quiet $remoteUrl $subFolder
    fi

    # Move into local git repo folder.
    cd $subFolder

    # Important if the repo aleady existed locally:
    # 1 verify upstream matches $remoteUrl
    actualRemote=`git config --get remote.origin.url | grep -o 'github.com.*' | sed 's/\.git//g'`
    count=`echo $remoteUrl | grep -i $actualRemote | wc -l`
    if [[ "$count" -eq "0" ]] ; then
        make_report "FAILED because local $subFolder is not pointed to expected remote $remoteUrl"

        continue
    fi
    # 2 Sync with remote
    git fetch

    # Does tag already exist? Check all tags.
    count=`git tag | grep $newGitTag | wc -l`
    if (( "$count" > "0" )) ; then
        make_report "Tag $newGitTag already exists" "$subFolder" "$remoteUrl"

        continue
    fi

    # Jump to latest commit for branch
    git checkout $gitBranch
    git pull

    # Jump to commit hash.
    if is_empty $hashValue ; then
        # No commit hash provided. Use short hash from latest commit in desired branch.
        hashValue=`git log --pretty=format:"%h" -1`
    else
        # Ensure hash exists by jumping to that point in time.
        # This also allows us to validate local tag creation below.
        git checkout -f $hashValue
    fi

    # Does current "long hash" contain the hash we expect?
    count=`git rev-parse HEAD | grep -i $hashValue | wc -l`
    if [[ "$count" -eq "0" ]] ; then
        make_report "FAILED to checkout hash $hashValue" "$subFolder" "$remoteUrl"

        continue
    fi

    # Make tag
    git tag -a $newGitTag $hashValue -m "$tagMessage"

    # Was tag created locally?
    count=`get_current_local_tags | grep $newGitTag | wc -l`
    if [[ "$count" -eq "0" ]] ; then
        make_report "FAILED to create tag $newGitTag" "$subFolder" "$remoteUrl"

        continue
    else
        make_report "SUCCESSFULLY created tag $newGitTag at commit $hashValue" "$subFolder" "$remoteUrl"
    fi

    # Push tag to upstream
    git push --tags

done < $tagFile

echo
echo Summary:
echo -e $finalReport
echo
