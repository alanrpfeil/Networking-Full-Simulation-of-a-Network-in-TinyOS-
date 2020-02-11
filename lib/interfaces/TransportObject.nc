interface TransportObject {
//commands:
command void startServer(uint8_t port);
command void startClient(uint8_t dest, uint8_t srcPort, uint8_t destPort, uint16_t data);
command void closeClient(uint8_t srcPort, uint8_t destPort, uint8_t dest);
command void whisperMsg(uint8_t src, uint8_t dest, uint8_t srcPort, uint8_t destPort, uint8_t* message);
command uint8_t copyRcvdBuffer(uint8_t serverNode, uint8_t* buff, uint8_t buffLen);
command error_t copyChatRoomUsers(uint8_t dest, uint8_t* username, bool used, uint8_t srcPort, uint8_t destPort);
}