import {StyleSheet, Text, View} from "react-native";

export default function App() {
    return (
        <View style={styles.container}>
            <Text style={styles.text}>Repack TV Repro</Text>
        </View>
    );
}

const styles = StyleSheet.create({
    container: {
        alignItems: "center",
        backgroundColor: "#101820",
        flex: 1,
        justifyContent: "center",
    },
    text: {
        color: "#ffffff",
        fontSize: 48,
    },
});
