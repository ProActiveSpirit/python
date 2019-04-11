#!/usr/bin/env bash
set -Eeuo pipefail

declare -A aliases=(
	[3.8-rc]='rc'
	[3.7]='3 latest'
	[2.7]='2'
)

defaultDebianSuite='stretch'
defaultAlpineVersion='3.9'

self="$(basename "$BASH_SOURCE")"
cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

versions=( */ )
versions=( "${versions[@]%/}" )

# sort version numbers with highest first
IFS=$'\n'; versions=( $(echo "${versions[*]}" | sort -rV) ); unset IFS

# get the most recent commit which modified any of "$@"
fileCommit() {
	git log -1 --format='format:%H' HEAD -- "$@"
}

# get the most recent commit which modified "$1/Dockerfile" or any file COPY'd from "$1/Dockerfile"
dirCommit() {
	local dir="$1"; shift
	(
		cd "$dir"
		fileCommit \
			Dockerfile \
			$(git show HEAD:./Dockerfile | awk '
				toupper($1) == "COPY" {
					for (i = 2; i < NF; i++) {
						print $i
					}
				}
			')
	)
}

getArches() {
	local repo="$1"; shift
	local officialImagesUrl='https://github.com/docker-library/official-images/raw/master/library/'

	eval "declare -g -A parentRepoToArches=( $(
		find -name 'Dockerfile' -exec awk '
				toupper($1) == "FROM" && $2 !~ /^('"$repo"'|scratch|.*\/.*)(:|$)/ {
					print "'"$officialImagesUrl"'" $2
				}
			' '{}' + \
			| sort -u \
			| xargs bashbrew cat --format '[{{ .RepoName }}:{{ .TagName }}]="{{ join " " .TagEntry.Architectures }}"'
	) )"
}
getArches 'python'

cat <<-EOH
# this file is generated via https://github.com/docker-library/python/blob/$(fileCommit "$self")/$self

Maintainers: Tianon Gravi <admwiggin@gmail.com> (@tianon),
             Joseph Ferguson <yosifkit@gmail.com> (@yosifkit)
GitRepo: https://github.com/docker-library/python.git
EOH

# prints "$2$1$3$1...$N"
join() {
	local sep="$1"; shift
	local out; printf -v out "${sep//%/%%}%s" "$@"
	echo "${out#$sep}"
}

for version in "${versions[@]}"; do
	rcVersion="${version%-rc}"

	for v in \
		{stretch,jessie}{,/slim} \
		alpine{3.9,3.8} \
		windows/windowsservercore-{ltsc2016,1803,1809} \
	; do
		dir="$version/$v"
		variant="$(basename "$v")"

		if [ "$variant" = 'slim' ]; then
			# convert "slim" into "slim-jessie"
			# https://github.com/docker-library/ruby/pull/142#issuecomment-320012893
			variant="$variant-$(basename "$(dirname "$v")")"
		fi

		[ -f "$dir/Dockerfile" ] || continue

		commit="$(dirCommit "$dir")"

		fullVersion="$(git show "$commit":"$dir/Dockerfile" | awk '$1 == "ENV" && $2 == "PYTHON_VERSION" { print $3; exit }')"

		versionAliases=(
			$fullVersion
			$version
			${aliases[$version]:-}
		)

		variantAliases=( "${versionAliases[@]/%/-$variant}" )
		case "$variant" in
			*-"$defaultDebianSuite") # "slim-stretch", etc need "slim"
				variantAliases+=( "${versionAliases[@]/%/-${variant%-$defaultDebianSuite}}" )
				;;
			"alpine${defaultAlpineVersion}")
				variantAliases+=( "${versionAliases[@]/%/-alpine}" )
				;;
		esac
		variantAliases=( "${variantAliases[@]//latest-/}" )

		case "$v" in
			windows/*) variantArches='windows-amd64' ;;
			*)
				variantParent="$(awk 'toupper($1) == "FROM" { print $2 }' "$dir/Dockerfile")"
				variantArches="${parentRepoToArches[$variantParent]}"
				;;
		esac

		sharedTags=()
		for windowsShared in windowsservercore nanoserver; do
			if [[ "$variant" == "$windowsShared"* ]]; then
				sharedTags=( "${versionAliases[@]/%/-$windowsShared}" )
				sharedTags=( "${sharedTags[@]//latest-/}" )
				break
			fi
		done
		if [ "$variant" = "$defaultDebianSuite" ] || [[ "$variant" == 'windowsservercore'* ]]; then
			sharedTags+=( "${versionAliases[@]}" )
		fi

		echo
		echo "Tags: $(join ', ' "${variantAliases[@]}")"
		if [ "${#sharedTags[@]}" -gt 0 ]; then
			echo "SharedTags: $(join ', ' "${sharedTags[@]}")"
		fi
		cat <<-EOE
			Architectures: $(join ', ' $variantArches)
			GitCommit: $commit
			Directory: $dir
		EOE
		[[ "$v" == windows/* ]] && echo "Constraints: $variant"
	done
done
