#ifndef TCP_h
#define TCP_h

#define TCP_INITIAL_RTT 0
#define TCP_INITIAL_RTT_VAR 0
#define TCP_INITIAL_RTO 0	//RTO = Recovery Time Objective
#define TCP_MIN_CWND 1
#define TCP_MAX_CWND 128	//possible to change; could be wrong
#define TCP_RTT_ALPHA 0.8	//smoothing factor (0.8-0.9)
#define TCP_RTT_BETA 1.5	//delay (1.3-2.0)
#define TCP_FT_DUP 3	//3 duplicates warrant a retransmission; change to AIMD
#define TCP_DEADLOCK_ACK_RTO 100 //timeout for deadlock; could change
#define BETTER_TTL 32	//could change


enum tcp_flags{
    DATA,
    ACK,
    SYN,
	SYN_ACK,
	FIN,
	FIN_ACK,
	UPD,
};

typedef struct TCP{
	//nx_uint8_t src;		//may not be used
	//nx_uint8_t dest;	//may not be used
	uint8_t srcPort;
	uint8_t destPort;
	uint16_t seq;
	//nx_uint16_t ack;
	
	enum tcp_flags flags;
	uint8_t length;		// variable type not confirmed
	
	//flags//
	//bool NS;
	//bool CWR;	//congestion Window Reduced flag
	//bool ECE;
	//bool URG;
	uint8_t ack;	//* - flag that's set to 1 if the ack field contains a valid acknum. 1 if valid.
	//bool PSH;
	//bool RST;
	//nx_uint8_t SYN;	//* - synchronize sequence numbers. Only the first packet sent from each end should have this flag set to 1
	//nx_uint8_t FIN;	//* - last packet from sender true/false.
	
	uint16_t advwin; //advertised window
	
	uint8_t payload[16];	//message

}TCP;

#endif