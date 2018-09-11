pragma solidity ^0.4.23; // solhint-disable-line

import "./SafeMath.sol";
import "zeppelin-solidity/contracts/ownership/Ownable.sol";


/// @title RockPaperScissors Smart Contract
/// @author Micah Uhrlass
/// @notice Hosts Rock-Paper-Scissors matches for two
contract RockPaperScissors is Ownable {
    using SafeMath for uint256;

    uint256 matchExpiry = 200;
    uint256 roundExpiry = 25;
    address queuedPlayer;

    mapping(address => uint256) public balances;
    mapping(address => uint256) private wagers;
    mapping(string => uint256) private matchDeadlines;
    mapping(string => uint256) private roundDeadlines;
    mapping(address => address) private partners;
    mapping(address => bytes32) private shots;
    mapping(address => string) private verifiedShots;
    
    enum Shot {Rock, Paper, Scissors}

    event PlayerEnrolled(address player, uint256 wager);
    event MatchCreated(address player1, address player2, uint256 blockDeadline);
    event Tie(address player1, address player2, string sharedShot);
    event Reward(address winner, uint256 winnings);
    
    function generateHash(string shot, string randomStr, address player) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(shot, randomStr, player));
    }

    function enroll(uint256 fromExistingBalance) public payable {
        require(msg.value > 0, "msg.value equals 0");
        require(!wagers[msg.sender], "you are already in a match or in queue for the next match");
        require(fromExistingBalance >= balances[msg.sender], "insufficient funds indicated to pull from existing balance");

        if (queuedPlayer) createMatch(msg.sender);
        else enqueue(msg.sender);
        balances[msg.sender] = balances[msg.sender].sub(fromExistingBalance);
        wagers[msg.sender] = msg.value.add(fromExistingBalance);
        emit PlayerEnrolled(msg.sender, (msg.value.add(fromExistingBalance)));
    }

    function createMatch(address player2) private {
        queuedPlayer = address(0);
        // start match expiry countdown
        matchDeadlines[queuedPlayer + player2] = block.number.add(matchExpiry);
        partners[queuedPlayer] = player2;
        partners[player2] = queuedPlayer;
        emit MatchCreated(queuedPlayer, player2, (block.number.add(matchExpiry)));
    }
    
    function shoot(bytes32 shotHash) public {
        require(!shots[msg.sender], "shot already submitted for current round");
        shots[msg.sender] = shotHash;
    }

    function revealShot(string shot, string randomStr) public {
        require(shot == Shot.Rock || shot == Shot.Paper || shot == Shot.Scissors, "invalid shot! note: shot is case-sensitive");
        bytes32 expectedHash = generateHash(shot, randomStr, msg.sender);
        require(expectedHash == shots[msg.sender], "this does not match your initial submission. please try again.");
        verifiedShots[msg.sender] = shot;
        delete shots[msg.sender];
        // start round expiry countdown
        roundDeadlines[queuedPlayer + player2] = block.number.add(roundExpiry);
        evaluateShots(msg.sender);
    }

    function evaluateShots(address player1) private {
        require(verifiedShots[player1], "player1 missing verified shot");
        address player2 = partners[player1];
        require(verifiedShots[player2], "player2 missing verified shot");
        
        string p1shot = verifiedShots[player1];
        string p2shot = verifiedShots[player2];

        if (p1shot == p2shot) {
            delete verifiedShots[player1];
            delete verifiedShots[player2];
            emit Tie(player1, player2, p1shot);
        }
        else {
            if (p1shot == Shot.Rock && p2shot == Shot.Paper) {reward(player2, player1);}
            else if (p1shot == Shot.Rock && p2shot == Shot.Scissors) {reward(player1, player2);}
            else if (p1shot == Shot.Paper && p2shot == Shot.Rock) {reward(player1, player2);}
            else if (p1shot == Shot.Paper && p2shot == Shot.Scissors) {reward(player2, player1);}
            else if (p1shot == Shot.Scissors && p2shot == Shot.Rock) {reward(player2, player1);}
            else if (p1shot == Shot.Scissors && p2shot == Shot.Paper) {reward(player1, player2);}
        }
    }

    function reward(address winner, address loser) private {
        uint256 reward = 0;
        uint256 winningWager = wagers[winner];
        uint256 losingWager = wagers[loser];
        
        // set reward as the lower of the two wagers
        if (winningWager >= losingWager) {reward = winningWager;}
        else (reward = losingWager);

        // move reward amount from both players' wagers to winner's balance
        balances[winner] = balances[winner].add(winningWager.add(reward));
        delete wagers[winner];
        delete wagers[loser];

        // deactivate players
        delete matchDeadlines[winner + loser];
        delete matchDeadlines[loser + winner];
        delete roundDeadlines[winner + loser];
        delete roundDeadlines[loser + winner];
        delete verifiedShots[winner];
        delete verifiedShots[loser];
        delete partners[winner];
        delete partners[loser];

        emit Reward(winner, reward);
    }
    
    function withdraw() public {
        address partner = partners[msg.sender];
        require(partner != address(0), "reward has already been paid out");
        require(verifiedShot[msg.sender], "you have not verified your shot yet");
        require(
            roundDeadlines[msg.sender + partner] >= block.number ||
            roundDeadlines[partner + msg.sender] >= block.number,
            "round deadline not yet met");
        
        // reward and send balance
        reward(msg.sender, partner);
        uint256 balance = balances[msg.sender];
        require(balance > 0, "you've won the match by default but have nothing to withdraw");
        balances[msg.sender] = 0;
        emit WithdrawalMade(msg.sender, balance);
        msg.sender.transfer(balance);
    }

    function withdraw(address p1, address p2) public onlyOwner {
        require(matchDeadlines[p1 + p2] >= block.number, "match deadline not yet met");
        
        // collect wagers from both players
        uint256 allowance = wagers[p1].add(wagers[p2]);
        require(allowance > 0, "nothing to withdraw, allowance equals 0");
        delete wagers[p1];
        delete wagers[p2];

        // deactivate players
        delete matchDeadlines[p1 + p2];
        delete roundDeadlines[p1 + p2];
        delete verifiedShots[p1];
        delete verifiedShots[p2];
        delete partners[p1];
        delete partners[p2];      
        
        emit WithdrawalMade(msg.sender, allowance);
        msg.sender.transfer(allowance);
    }
}