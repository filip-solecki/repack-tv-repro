// Repack re-evaluates this config during a repack and injects the icons it finds here.
// The art below is deliberately different from the art committed in ios/, so "did the swap
// happen" is answerable by looking at one screenshot.
const TV = "./assets/tv/repacked";

module.exports = {
    expo: {
        name: "Repack TV Repro",
        slug: "repack-tv-repro",
        version: "1.0.0",
        platforms: ["ios"],
        ios: {
            bundleIdentifier: "dev.repro.repacktv",
        },
        plugins: [
            [
                "@react-native-tvos/config-tv",
                {
                    isTV: true,
                    appleTVImages: {
                        icon: `${TV}/icon-1280x768.png`,
                        iconSmall: `${TV}/icon-400x240.png`,
                        iconSmall2x: `${TV}/icon-800x480.png`,
                        topShelf: `${TV}/top-shelf-1920x720.png`,
                        topShelf2x: `${TV}/top-shelf-3840x1440.png`,
                        topShelfWide: `${TV}/top-shelf-wide-2320x720.png`,
                        topShelfWide2x: `${TV}/top-shelf-wide-4640x1440.png`,
                    },
                },
            ],
        ],
    },
};
