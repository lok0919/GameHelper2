.PHONY: all build restore clean publish release zip

# Solution file
SLN = GameOverlay.sln

# Image defined in devcontainer.json
IMAGE = mcr.microsoft.com/dotnet/sdk:10.0

# Base podman command with necessary Arch/Podman flags
PODMAN_RUN = podman run --rm \
	-v "$(CURDIR):/workspace:Z" \
	-v "$(HOME)/.nuget/packages:/tmp/nuget:Z" \
	-e NUGET_PACKAGES=/tmp/nuget \
	-w /workspace \
	--userns=keep-id \
	--security-opt label=disable \
	$(IMAGE)

# Default target
all: build

# Standard dotnet commands routed through the container
build:
	$(PODMAN_RUN) dotnet build $(SLN)

restore:
	$(PODMAN_RUN) dotnet restore $(SLN)

clean:
	$(PODMAN_RUN) dotnet clean $(SLN)
	find . -type d \( -name "bin" -o -name "obj" \) -prune -exec rm -rf {} +

publish:
	$(PODMAN_RUN) dotnet publish $(SLN) -c Release

release:
	$(PODMAN_RUN) dotnet build $(SLN) -c Release

zip:
	cd GameHelper/bin/Release/net10.0-windows/win-x64 && python3 -m zipfile -c "$(CURDIR)/GH2_$$(date +%Y%m%d%H%M).zip" .
